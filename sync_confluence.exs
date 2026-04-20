Mix.install([
  {:req, "~> 0.5"},
  {:floki, "~> 0.37"}
])

config_file_name = "sync_confluence.local.exs"
script_dir = __ENV__.file |> Path.expand() |> Path.dirname()
config_file_path = Path.join(script_dir, config_file_name)
example_config_file_path = Path.join(script_dir, "sync_confluence.local.example.exs")

raw_config =
  cond do
    File.exists?(config_file_path) ->
      case Code.eval_file(config_file_path) do
        {%{} = map, _binding} -> map
        {list, _binding} when is_list(list) -> Map.new(list)
        {other, _binding} -> raise "Expected #{config_file_name} to return a map or keyword list, got: #{inspect(other)}"
      end

    true ->
      %{}
  end

fetch_config = fn key, default ->
  Map.get(raw_config, key) || Map.get(raw_config, Atom.to_string(key)) || default
end

config = %{
  config_file_name: config_file_name,
  config_file_path: config_file_path,
  example_config_file_path: example_config_file_path,
  config_file_exists?: File.exists?(config_file_path),
  confluence_base_url: fetch_config.(:confluence_base_url, "https://your-site.atlassian.net") |> to_string() |> String.trim_trailing("/"),
  confluence_email: fetch_config.(:confluence_email, "you@example.com") |> to_string() |> String.trim(),
  confluence_api_token: fetch_config.(:confluence_api_token, "replace-me") |> to_string() |> String.trim(),
  local_sync_dir: fetch_config.(:local_sync_dir, "./confluence-sync") |> to_string(),
  sync_child_pages: fetch_config.(:sync_child_pages, true),
  sync_targets: fetch_config.(:sync_targets, [])
}

defmodule SyncConfluence.Util do
  def slugify(nil), do: "untitled"

  def slugify(value) do
    value
    |> String.normalize(:nfd)
    |> String.downcase()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "untitled"
      slug -> slug
    end
  end

  def safe_file_stem(nil), do: "Untitled"

  def safe_file_stem(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r{[/:\\]+}u, " - ")
    |> String.replace(~r/[?*"<>|]/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim(". ")
    |> case do
      "" -> "Untitled"
      stem -> stem
    end
  end

  def parse_page_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, "Parent value is empty."}

      String.match?(trimmed, ~r/^\d+$/) ->
        {:ok, trimmed}

      true ->
        parse_page_id_from_url(trimmed)
    end
  end

  def parse_page_id_from_url(url) do
    with %URI{} = uri <- URI.parse(url),
         id when is_binary(id) <- page_id_from_uri(uri) do
      {:ok, id}
    else
      _ -> {:error, "Could not extract a Confluence page ID from #{inspect(url)}."}
    end
  end

  def page_id_from_uri(%URI{query: query, path: path}) do
    query_params = URI.decode_query(query || "")

    cond do
      page_id = query_params["pageId"] ->
        page_id

      match = Regex.run(~r{/pages/(\d+)(?:/|$)}, path || "") ->
        Enum.at(match, 1)

      match = Regex.run(~r{/spaces/[^/]+/pages/(\d+)(?:/|$)}, path || "") ->
        Enum.at(match, 1)

      true ->
        nil
    end
  end

  def relative_link(from_path, to_path) do
    from_dir = Path.dirname(from_path)
    Path.relative_to(to_path, from_dir)
  end

  def ensure_directory(path) do
    path |> Path.dirname() |> File.mkdir_p!()
  end

  def yaml_frontmatter(metadata) do
    lines =
      metadata
      |> Enum.map(fn {key, value} ->
        "#{key}: #{yaml_scalar(value)}"
      end)
      |> Enum.join("\n")

    "---\n" <> lines <> "\n---\n\n"
  end

  defp yaml_scalar(nil), do: "null"
  defp yaml_scalar(true), do: "true"
  defp yaml_scalar(false), do: "false"
  defp yaml_scalar(value) when is_integer(value), do: Integer.to_string(value)

  defp yaml_scalar(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"#{escaped}\""
  end
  def normalize_markdown(markdown) do
    markdown
    |> String.replace("\r\n", "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> Kernel.<>("\n")
  end

  def header_value(headers, name) do
    normalized_name = String.downcase(name)

    headers
    |> Enum.find_value(fn
      {header_name, value} when is_binary(header_name) ->
        if String.downcase(header_name) == normalized_name, do: value, else: nil

      _ ->
        nil
    end)
  end
end

defmodule SyncConfluence.Logger do
  def log(message, verbose \\ true) do
    if verbose, do: IO.puts(message)
  end
end

defmodule SyncConfluence.Client do
  alias SyncConfluence.Logger
  alias SyncConfluence.Util

  def new(config) do
    auth =
      Base.encode64("#{config.confluence_email}:#{config.confluence_api_token}")

    %{
      base_url: config.confluence_base_url,
      req:
        Req.new(
          base_url: config.confluence_base_url,
          headers: [
            {"accept", "application/json"},
            {"authorization", "Basic #{auth}"},
            {"content-type", "application/json"}
          ],
          connect_options: [timeout: 30_000],
          receive_timeout: 120_000
        )
    }
  end

  def fetch_tree(client, root_page_id, include_children, verbose) do
    with {:ok, _root_page} <- fetch_page(client, root_page_id),
         {:ok, descendants} <- maybe_fetch_descendants(client, root_page_id, include_children, verbose) do
      descendant_nodes =
        descendants
        |> Enum.map(&normalize_descendant(&1, root_page_id))

      page_ids =
        [%{id: root_page_id, type: "page"} | descendant_nodes]
        |> Enum.filter(&(&1.type == "page"))
        |> Enum.map(& &1.id)
        |> Enum.uniq()

      Logger.log("Fetching #{length(page_ids)} page bodies for root #{root_page_id}...", verbose)

      pages = fetch_pages_map(client, page_ids, verbose, allow_missing: true)

      case pages do
        {:error, reason} ->
          {:error, reason}

        page_map ->
          root_node =
            page_map
            |> Map.fetch!(root_page_id)
            |> Map.put(:root_parent_id, root_page_id)
            |> Map.put(:depth, 0)
            |> Map.put(:child_position, 0)

          nodes =
            [root_node | descendant_nodes]
            |> Enum.map(fn node ->
              case Map.get(page_map, node.id) do
                nil ->
                  Map.put(node, :root_parent_id, root_page_id)

                page ->
                  node
                  |> Map.merge(page)
                  |> Map.put(:root_parent_id, root_page_id)
              end
            end)
            |> Enum.filter(fn node ->
              node.type != "page" or Map.has_key?(node, :storage_value)
            end)

          {:ok, nodes}
      end
    end
  end

  def fetch_page_target_tree(client, target, verbose) do
    with {:ok, nodes} <- fetch_tree(client, target.page_id, target.include_children, verbose) do
      synthetic_root = target_root_node(target)

      adjusted_nodes =
        nodes
        |> Enum.map(fn node ->
          normalized_parent_id =
            if node.id == target.page_id do
              target.id
            else
              node.parent_id
            end

          node
          |> Map.put(:root_parent_id, target.id)
          |> Map.put(:parent_id, normalized_parent_id)
        end)

      {:ok, [synthetic_root | adjusted_nodes]}
    end
  end

  def fetch_descendants(client, page_id, verbose) do
    fetch_supported_children_recursive(client, "page", page_id, 1, verbose)
  end

  def fetch_page(client, page_id) do
    case request_json(
           client,
           :get,
           "/wiki/api/v2/pages/#{page_id}",
           params: [{"body-format", "storage"}, {"include-version", "true"}]
         ) do
      {:ok, body, _response} ->
        {:ok,
         %{
           id: body["id"],
           type: "page",
           title: body["title"],
           parent_id: body["parentId"],
           parent_type: body["parentType"],
           space_id: body["spaceId"],
           version: get_in(body, ["version", "number"]),
           storage_value: get_in(body, ["body", "storage", "value"]) || "",
           source_url: source_url(client.base_url, body["id"], body["_links"] || %{})
         }}

      {:error, reason} ->
        {:error, "Could not fetch page #{page_id}: #{reason}"}
    end
  end

  defp fetch_pages_map(client, page_ids, _verbose, opts) do
    allow_missing = Keyword.get(opts, :allow_missing, false)

    Enum.reduce_while(page_ids, %{}, fn page_id, acc ->
      case fetch_page(client, page_id) do
        {:ok, page} ->
          {:cont, Map.put(acc, page_id, page)}

        {:error, reason} ->
          if allow_missing and missing_page_error?(reason) do
            Logger.log("Skipping missing or inaccessible child page #{page_id}: #{reason}", true)
            {:cont, acc}
          else
            {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp missing_page_error?(reason) when is_binary(reason) do
    String.contains?(reason, "HTTP 404")
  end

  def convert_storage_to_export_view(client, page_id, storage_html) do
    payload = %{
      "value" => storage_html,
      "representation" => "storage"
    }

    with {:ok, %{"asyncId" => async_id}, _response} <-
           request_json(
             client,
             :post,
             "/wiki/rest/api/contentbody/convert/async/export_view",
             params: [{"contentIdContext", page_id}],
             json: payload
           ) do
      poll_conversion(client, async_id, 20)
    else
      {:ok, other, _response} ->
        {:error, "Unexpected conversion response for page #{page_id}: #{inspect(other)}"}

      {:error, reason} ->
        {:error, "Could not start conversion for page #{page_id}: #{reason}"}
    end
  end

  defp poll_conversion(_client, _async_id, 0) do
    {:error, "Timed out while waiting for Confluence content body conversion."}
  end

  defp poll_conversion(client, async_id, attempts_left) do
    case request_json(client, :get, "/wiki/rest/api/contentbody/convert/async/#{async_id}") do
      {:ok, %{"value" => html}, _response} when is_binary(html) ->
        {:ok, html}

      {:ok, %{"status" => status}, _response} when status in ["WORKING", "QUEUED"] ->
        Process.sleep(500)
        poll_conversion(client, async_id, attempts_left - 1)

      {:ok, %{"error" => error}, _response} ->
        {:error, "Confluence conversion failed: #{error}"}

      {:ok, body, _response} ->
        {:error, "Unexpected conversion poll payload: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp paginate_json(client, initial_url, initial_params, verbose) do
    do_paginate_json(client, initial_url, initial_params, verbose, [])
  end

  defp maybe_fetch_descendants(_client, _page_id, false, _verbose), do: {:ok, []}
  defp maybe_fetch_descendants(client, page_id, true, verbose), do: fetch_descendants(client, page_id, verbose)

  defp fetch_direct_children(client, parent_type, parent_id, verbose) do
    path =
      case parent_type do
        "page" -> "/wiki/api/v2/pages/#{parent_id}/direct-children"
        "folder" -> "/wiki/api/v2/folders/#{parent_id}/direct-children"
        "database" -> "/wiki/api/v2/databases/#{parent_id}/direct-children"
        "embed" -> "/wiki/api/v2/embeds/#{parent_id}/direct-children"
        "whiteboard" -> "/wiki/api/v2/whiteboards/#{parent_id}/direct-children"
      end

    case paginate_json(
           client,
           path,
           [limit: 100],
           verbose
         ) do
      {:error, reason} when is_binary(reason) ->
        if is_missing_children_error?(reason) do
          Logger.log(
            "Skipping child traversal for #{parent_type} #{parent_id}: #{reason}",
            true
          )

          {:ok, []}
        else
          {:error, reason}
        end

      result ->
        result
    end
  end

  defp fetch_supported_children_recursive(client, parent_type, parent_id, depth, verbose) do
    with {:ok, children} <- fetch_direct_children(client, parent_type, parent_id, verbose) do
      children
      |> Enum.reduce_while({:ok, []}, fn child, {:ok, acc} ->
        child_type = child["type"] || infer_child_type(parent_type)

        cond do
          not supported_tree_type?(child_type) ->
            {:cont, {:ok, acc}}

          true ->
            node = normalize_child_node(child, child_type, parent_id, depth)

            case fetch_supported_children_recursive(client, child_type, child["id"], depth + 1, verbose) do
              {:ok, descendants} ->
                {:cont, {:ok, [[node | descendants] | acc]}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
        end
      end)
      |> case do
        {:ok, descendants} -> {:ok, descendants |> Enum.reverse() |> List.flatten()}
        error -> error
      end
    end
  end

  defp do_paginate_json(client, url, params, verbose, acc) do
    case request_json(client, :get, url, params: params) do
      {:ok, %{"results" => results} = body, _response} ->
        Logger.log("Fetched #{length(results)} items from #{url}.", verbose)

        case get_in(body, ["_links", "next"]) do
          next when is_binary(next) and next != "" ->
            do_paginate_json(client, next, [], verbose, acc ++ results)

          _ ->
            {:ok, acc ++ results}
        end

      {:ok, other, _response} ->
        {:error, "Unexpected pagination payload from #{url}: #{inspect(other)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_json(client, method, url, opts \\ [], retries_left \\ 4)

  defp request_json(client, method, url, opts, retries_left) do
    request_opts = Keyword.merge([method: method, url: url], opts)

    case Req.request(client.req, request_opts) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, response.body, response}

      {:ok, %Req.Response{status: 429} = response} ->
        retry_after(response.headers, retries_left, fn ->
          request_json(client, method, url, opts, retries_left - 1)
        end)

      {:ok, %Req.Response{status: status}} when status >= 500 and retries_left > 0 ->
        Process.sleep(backoff_ms(retries_left))
        request_json(client, method, url, opts, retries_left - 1)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, _exception} when retries_left > 0 ->
        Process.sleep(backoff_ms(retries_left))
        request_json(client, method, url, opts, retries_left - 1)

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp retry_after(headers, retries_left, next_request) when retries_left > 0 do
    wait_ms =
      headers
      |> Util.header_value("retry-after")
      |> case do
        nil -> backoff_ms(retries_left)
        value ->
          case Integer.parse(value) do
            {seconds, _rest} -> max(seconds, 1) * 1_000
            :error -> backoff_ms(retries_left)
          end
      end

    Process.sleep(wait_ms)
    next_request.()
  end

  defp retry_after(_headers, _retries_left, _next_request) do
    {:error, "Confluence rate limited the request too many times."}
  end

  defp backoff_ms(retries_left) do
    trunc(:math.pow(2, 5 - retries_left) * 500)
  end

  defp source_url(base_url, page_id, links) do
    case links["webui"] do
      path when is_binary(path) ->
        URI.merge(base_url, path) |> to_string()

      _ ->
        "#{base_url}/wiki/pages/viewpage.action?pageId=#{page_id}"
    end
  end

  defp normalize_descendant(node, root_parent_id) do
    %{
      id: node["id"],
      type: node["type"],
      title: node["title"] || "#{String.capitalize(node["type"] || "item")} #{node["id"]}",
      parent_id: node["parentId"],
      depth: node["depth"] || 0,
      child_position: node["childPosition"] || 0,
      root_parent_id: root_parent_id
    }
  end

  defp normalize_child_node(node, child_type, parent_id, depth) do
    %{
      "id" => node["id"],
      "type" => child_type,
      "title" => node["title"] || "#{String.capitalize(child_type)} #{node["id"]}",
      "parentId" => parent_id,
      "depth" => depth,
      "childPosition" => node["childPosition"] || 0
    }
  end

  defp supported_tree_type?(type) do
    type in ["page", "folder", "database", "embed", "whiteboard"]
  end

  defp infer_child_type("page"), do: "page"
  defp infer_child_type(type), do: type

  defp is_missing_children_error?(reason) do
    String.contains?(reason, "HTTP 404")
  end

  defp target_root_node(target) do
    %{
      id: target.id,
      type: "target",
      title: target.output_dir,
      parent_id: nil,
      root_parent_id: target.id,
      output_dir: target.output_dir
    }
  end
end

defmodule SyncConfluence.Tree do
  alias SyncConfluence.Util

  def enrich_paths(nodes, output_dir) do
    roots = Enum.filter(nodes, &(&1.id == &1.root_parent_id))
    nodes_by_root =
      nodes
      |> Enum.group_by(& &1.root_parent_id)

    page_counts_by_root =
      nodes
      |> Enum.filter(&(&1.type == "page"))
      |> Enum.frequencies_by(& &1.root_parent_id)

    root_dirs =
      roots
      |> Enum.map(fn root ->
        page_count = Map.get(page_counts_by_root, root.id, 0)
        configured_output_dir = Map.get(root, :output_dir)

        relative_dir =
          cond do
            configured_output_dir not in [nil, ""] ->
              configured_output_dir

            page_count > 1 ->
              Util.slugify(root.title)

            true ->
              ""
          end

        {root.id, relative_dir}
      end)
      |> Map.new()

    nodes_with_dirs =
      roots
      |> Enum.flat_map(fn root ->
        root_dir = Map.fetch!(root_dirs, root.id)
        root_nodes = Map.fetch!(nodes_by_root, root.id)
        assign_paths_for_root(root, root_nodes, root_dir)
      end)

    page_paths =
      nodes_with_dirs
      |> Enum.filter(&(&1.type == "page"))
      |> Enum.group_by(& &1.relative_dir)
      |> Enum.flat_map(fn {relative_dir, pages} ->
        file_names = assign_page_file_names(pages)

        Enum.map(pages, fn page ->
          {page.id, maybe_join(relative_dir, Map.fetch!(file_names, page.id))}
        end)
      end)
      |> Map.new()

    nodes_with_dirs
    |> Enum.map(fn node ->
      relative_path =
        case node.type do
          "page" -> Map.fetch!(page_paths, node.id)
          _ -> node.relative_dir
        end

      node
      |> Map.put(:relative_path, relative_path)
      |> Map.put(:absolute_path, Path.join(output_dir, relative_path))
    end)
  end

  defp assign_paths_for_root(root, root_nodes, root_dir) do
    children_by_parent =
      root_nodes
      |> Enum.reject(&(&1.id == root.id))
      |> Enum.group_by(& &1.parent_id)

    root_with_paths =
      root
      |> Map.put(:relative_dir, root_dir)
      |> Map.put(:relative_path, root_dir)

    [root_with_paths | assign_child_paths(root.id, children_by_parent, root_dir)]
  end

  defp assign_child_paths(parent_id, children_by_parent, current_dir) do
    children =
      children_by_parent
      |> Map.get(parent_id, [])
      |> Enum.sort_by(&{&1.child_position || 0, &1.title || "", &1.id})

    folder_names =
      children
      |> Enum.filter(&folder_type?/1)
      |> assign_directory_names()

    Enum.flat_map(children, fn child ->
      cond do
        child.type == "page" ->
          page =
            child
            |> Map.put(:relative_dir, current_dir)
            |> Map.put(:relative_path, current_dir)

          [page | assign_child_paths(child.id, children_by_parent, current_dir)]

        folder_type?(child) ->
          folder_dir = maybe_join(current_dir, Map.fetch!(folder_names, child.id))

          folder =
            child
            |> Map.put(:relative_dir, folder_dir)
            |> Map.put(:relative_path, folder_dir)

          [folder | assign_child_paths(child.id, children_by_parent, folder_dir)]

        true ->
          assign_child_paths(child.id, children_by_parent, current_dir)
      end
    end)
  end

  defp assign_page_file_names(pages) do
    pages
    |> Enum.map(fn page ->
      {page.id, Util.safe_file_stem(page.title)}
    end)
    |> assign_unique_names(fn stem, _id -> "#{stem}.md" end, fn stem, id -> "#{stem} (#{id}).md" end)
  end

  defp assign_directory_names(nodes) do
    nodes
    |> Enum.map(fn node ->
      {node.id, Util.safe_file_stem(node.title)}
    end)
    |> assign_unique_names(fn stem, _id -> stem end, fn stem, id -> "#{stem} (#{id})" end)
  end

  defp assign_unique_names(base_names, unique_name_fun, duplicate_name_fun) do
    counts =
      base_names
      |> Enum.frequencies_by(fn {_id, stem} -> stem end)

    base_names
    |> Enum.map(fn {id, stem} ->
      name =
        if Map.get(counts, stem, 0) > 1 do
          duplicate_name_fun.(stem, id)
        else
          unique_name_fun.(stem, id)
        end

      {id, name}
    end)
    |> Map.new()
  end

  defp folder_type?(node) do
    node.type in ["folder", "database", "embed", "whiteboard"]
  end

  defp maybe_join("", file_name), do: file_name
  defp maybe_join(relative_dir, file_name), do: Path.join(relative_dir, file_name)
end

defmodule SyncConfluence.Markdown do
  alias SyncConfluence.Util

  def from_html(html, current_page, local_pages_by_id) do
    {:ok, nodes} = Floki.parse_fragment(html)

    nodes
    |> Enum.map(&render_node(&1, %{page: current_page, pages_by_id: local_pages_by_id, list_depth: 0}))
    |> Enum.join()
    |> postprocess_markdown()
  end

  defp render_node(text, _ctx) when is_binary(text) do
    text
    |> String.replace(~r/\s+/u, " ")
  end

  defp render_node({"br", _attrs, _children}, _ctx), do: "  \n"
  defp render_node({"hr", _attrs, _children}, _ctx), do: "\n\n---\n\n"

  defp render_node({"h" <> level, _attrs, children}, ctx) when level in ["1", "2", "3", "4", "5", "6"] do
    heading = String.duplicate("#", String.to_integer(level))
    "\n\n#{heading} #{inline(children, ctx)}\n\n"
  end

  defp render_node({"p", _attrs, children}, ctx) do
    content = inline(children, ctx)
    if content == "", do: "", else: "\n\n#{content}\n\n"
  end

  defp render_node({"strong", _attrs, children}, ctx), do: wrap_inline("**", children, ctx)
  defp render_node({"b", _attrs, children}, ctx), do: wrap_inline("**", children, ctx)
  defp render_node({"em", _attrs, children}, ctx), do: wrap_inline("*", children, ctx)
  defp render_node({"i", _attrs, children}, ctx), do: wrap_inline("*", children, ctx)

  defp render_node({"code", _attrs, children}, _ctx) do
    text = Floki.text(children) |> String.trim()
    if text == "", do: "", else: "`#{text}`"
  end

  defp render_node({"pre", _attrs, children}, _ctx) do
    code =
      children
      |> Floki.text(sep: "")
      |> String.trim("\n")

    "\n\n```\n#{code}\n```\n\n"
  end

  defp render_node({"blockquote", _attrs, children}, ctx) do
    body =
      children
      |> Enum.map(&render_node(&1, ctx))
      |> Enum.join()
      |> String.trim()
      |> String.split("\n")
      |> Enum.map_join("\n", fn line ->
        if String.trim(line) == "", do: ">", else: "> #{line}"
      end)

    "\n\n#{body}\n\n"
  end

  defp render_node({"ul", _attrs, children}, ctx) do
    render_list(children, ctx, :unordered)
  end

  defp render_node({"ol", _attrs, children}, ctx) do
    render_list(children, ctx, :ordered)
  end

  defp render_node({"a", attrs, children}, ctx) do
    href = attr(attrs, "href")
    text = inline(children, ctx)
    label = if text == "", do: href || "", else: text

    case rewrite_href(href, ctx) do
      nil -> label
      rewritten -> "[#{label}](#{rewritten})"
    end
  end

  defp render_node({"img", attrs, _children}, _ctx) do
    src = attr(attrs, "src")
    alt = attr(attrs, "alt") || ""

    if src do
      "![#{alt}](#{src})"
    else
      ""
    end
  end

  defp render_node({"table", _attrs, children}, _ctx) do
    rows =
      Floki.find(children, "tr")
      |> Enum.map(fn {"tr", _tr_attrs, cells} ->
        cells
        |> Enum.filter(fn
          {tag, _, _} when tag in ["th", "td"] -> true
          _ -> false
        end)
        |> Enum.map(fn {_tag, _attrs, cell_children} ->
          cell_children
          |> Floki.text(sep: " ")
          |> String.replace(~r/\s+/u, " ")
          |> String.trim()
        end)
      end)
      |> Enum.reject(&Enum.empty?/1)

    case rows do
      [] ->
        ""

      [header | rest] ->
        separator = Enum.map_join(header, " | ", fn _ -> "---" end)
        body_rows = Enum.map_join(rest, "\n", &("| " <> Enum.join(&1, " | ") <> " |"))
        rows_markdown = if(body_rows == "", do: "", else: body_rows <> "\n")

        "\n\n| #{Enum.join(header, " | ")} |\n| #{separator} |\n#{rows_markdown}\n"
    end
  end

  defp render_node({tag, _attrs, children}, ctx)
       when tag in ["div", "span", "section", "article", "main", "body", "html", "header", "footer", "nav"] do
    children
    |> Enum.map(&render_node(&1, ctx))
    |> Enum.join()
  end

  defp render_node({_tag, _attrs, children}, ctx) do
    children
    |> Enum.map(&render_node(&1, ctx))
    |> Enum.join()
  end

  defp wrap_inline(wrapper, children, ctx) do
    content = inline(children, ctx)
    if content == "", do: "", else: "#{wrapper}#{content}#{wrapper}"
  end

  defp inline(children, ctx) do
    children
    |> Enum.map(&render_node(&1, ctx))
    |> Enum.join()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp render_list(children, ctx, mode) do
    items =
      children
      |> Enum.filter(fn
        {"li", _, _} -> true
        _ -> false
      end)

    list_ctx = %{ctx | list_depth: ctx.list_depth + 1}

    rendered =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn
        {{"li", _attrs, li_children}, index} ->
          marker =
            case mode do
              :unordered -> "- "
              :ordered -> "#{index}. "
            end

          content =
            li_children
            |> Enum.map(&render_node(&1, list_ctx))
            |> Enum.join()
            |> String.trim()

          indent = String.duplicate("  ", ctx.list_depth)
          lines = String.split(content, "\n")

          case lines do
            [] ->
              "#{indent}#{marker}"

            [first | rest] ->
              rest_text =
                rest
                |> Enum.map_join("\n", fn line ->
                  if String.trim(line) == "", do: "", else: "#{indent}  #{line}"
                end)
                |> String.trim_trailing()

              item_text = "#{indent}#{marker}#{first}"
              if(rest_text == "", do: item_text, else: item_text <> "\n" <> rest_text)
          end
      end)
      |> Enum.join("\n")

    "\n\n#{rendered}\n\n"
  end

  defp rewrite_href(nil, _ctx), do: nil

  defp rewrite_href("#" <> _ = href, _ctx), do: href

  defp rewrite_href(href, ctx) do
    uri = URI.parse(href)
    page_id = SyncConfluence.Util.page_id_from_uri(uri)

    cond do
      page_id && Map.has_key?(ctx.pages_by_id, page_id) ->
        target = Map.fetch!(ctx.pages_by_id, page_id)
        relative = Util.relative_link(ctx.page.relative_path, target.relative_path)
        anchor = if uri.fragment, do: "##{uri.fragment}", else: ""
        relative <> anchor

      String.starts_with?(href, "/") ->
        href

      true ->
        href
    end
  end

  defp attr(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  defp postprocess_markdown(markdown) do
    markdown
    |> String.replace(~r/[ \t]+\n/u, "\n")
    |> String.replace(~r/\n{3,}/u, "\n\n")
    |> String.trim()
    |> case do
      "" -> ""
      value -> value <> "\n"
    end
  end
end

defmodule SyncConfluence.Writer do
  alias SyncConfluence.Util

  def ensure_container(node, summary) do
    File.mkdir_p!(node.absolute_path)
    summary
  end

  def write_page(page, markdown_body, summary) do
    metadata = %{
      "confluence_page_id" => page.id,
      "title" => page.title,
      "space_id" => page.space_id,
      "parent_page_id" => if(page.parent_type == "page", do: page.parent_id, else: nil),
      "source_url" => page.source_url,
      "version" => page.version,
      "status" => "active"
    }

    content =
      metadata
      |> Util.yaml_frontmatter()
      |> Kernel.<>(Util.normalize_markdown(markdown_body))

    Util.ensure_directory(page.absolute_path)
    File.write!(page.absolute_path, content)

    increment_summary(summary, :written)
  end

  defp increment_summary(summary, key) do
    Map.update(summary, key, 1, &(&1 + 1))
  end
end

defmodule SyncConfluence do
  alias SyncConfluence.Client
  alias SyncConfluence.Logger
  alias SyncConfluence.Markdown
  alias SyncConfluence.Tree
  alias SyncConfluence.Util
  alias SyncConfluence.Writer

  def main(config, argv) do
    {opts, _args, invalid} =
      OptionParser.parse(argv,
        strict: [
          out: :string,
          parent: :keep,
          with_children: :boolean,
          without_children: :boolean,
          verbose: :boolean,
          help: :boolean
        ]
      )

    if invalid != [] do
      invalid_flags =
        invalid
        |> Enum.map(fn {flag, value} -> "#{flag}=#{inspect(value)}" end)
        |> Enum.join(", ")

      raise "Invalid option(s): #{invalid_flags}"
    end

    if opts[:help] do
      usage(config)
    else
      run_sync(config, opts)
    end
  end

  defp run_sync(config, opts) do
    ensure_config!(config)

    verbose = Keyword.get(opts, :verbose, false)
    client = Client.new(config)
    cli_parents = Keyword.get_values(opts, :parent)

    {summary, output_dir} =
      if cli_parents != [] do
        run_cli_sync(client, config, opts, cli_parents, verbose)
      else
        run_configured_sync(client, config, verbose)
      end

    IO.puts("")
    IO.puts("Sync complete.")
    IO.puts("Output directory: #{output_dir}")
    IO.puts("Written: #{summary.written}")
  end

  defp run_cli_sync(client, config, opts, cli_parents, verbose) do
    output_dir = Path.expand(Keyword.get(opts, :out, config.local_sync_dir), File.cwd!())
    include_children = child_page_setting(opts, config)
    parent_ids = parse_parent_ids!(cli_parents)
    child_page_label = if include_children, do: "enabled", else: "disabled"

    Logger.log("Preparing sync for #{length(parent_ids)} CLI root page(s)...", true)
    Logger.log("Child pages: #{child_page_label}", true)
    Logger.log("Local output directory: #{output_dir}", true)

    reset_directory!(output_dir)
    nodes = fetch_nodes!(client, parent_ids, include_children, verbose)
    summary = sync_target_nodes(nodes, output_dir, client, verbose, %{written: 0})

    {summary, output_dir}
  end

  defp run_configured_sync(client, config, verbose) do
    output_dir = Path.expand(config.local_sync_dir, File.cwd!())
    targets = normalize_config_targets!(config)

    Logger.log("Preparing sync for #{length(targets)} configured target(s)...", true)
    Logger.log("Local output directory: #{output_dir}", true)

    reset_directory!(output_dir)

    summary =
      Enum.reduce(targets, %{written: 0}, fn target, summary_acc ->
        child_note = if target.include_children, do: "with child pages", else: "without child pages"

        Logger.log(
          "Target #{target.output_dir}: #{target.source} (page, #{child_note})",
          true
        )

        nodes =
          case Client.fetch_page_target_tree(client, target, verbose) do
            {:ok, fetched_nodes} -> fetched_nodes
            {:error, reason} -> raise reason
          end

        sync_target_nodes(nodes, output_dir, client, verbose, summary_acc)
      end)

    {summary, output_dir}
  end

  defp sync_target_nodes(nodes, output_dir, client, verbose, summary) do
    enriched_nodes = Tree.enrich_paths(nodes, output_dir)
    container_nodes = Enum.filter(enriched_nodes, fn node -> node.type != "page" end)
    page_nodes = Enum.filter(enriched_nodes, fn node -> node.type == "page" end)
    pages_by_root_and_id = build_page_lookup(page_nodes)
    summary = Enum.reduce(container_nodes, summary, &Writer.ensure_container/2)

    sync_pages(page_nodes, client, pages_by_root_and_id, verbose, summary)
  end

  defp parse_parent_ids!([]) do
    raise "Please provide at least one --parent value or define sync_targets in the config file."
  end

  defp parse_parent_ids!(parent_values) do
    Enum.map(parent_values, fn value ->
      case Util.parse_page_id(value) do
        {:ok, id} -> id
        {:error, reason} -> raise reason
      end
    end)
  end

  defp normalize_config_targets!(config) do
    if config.sync_targets == [] do
      raise "Please define sync_targets in #{config.config_file_name} or pass --parent on the command line."
    end

    config.sync_targets
    |> Enum.with_index(1)
    |> Enum.map(fn {target, index} -> normalize_target!(target, index, config) end)
  end

  defp normalize_target!(target, index, config) when is_list(target) do
    normalize_target!(Map.new(target), index, config)
  end

  defp normalize_target!(%{} = target, index, config) do
    ensure_page_target!(target, config)

    source =
      target_value(target, :source, nil) ||
        raise "Each sync target in #{config.config_file_name} needs a source."

    output_dir =
      target_value(target, :output_dir, nil) ||
        raise "Each sync target in #{config.config_file_name} needs an output_dir."

    include_children =
      target_value(target, :include_children, config.sync_child_pages)
      |> normalize_boolean!("include_children", config)

    page_id =
      case Util.parse_page_id(source) do
        {:ok, id} -> id
        {:error, reason} -> raise reason
      end

    %{
      id: "target:#{index}:#{output_dir}",
      source: source,
      page_id: page_id,
      output_dir: output_dir,
      include_children: include_children
    }
  end

  defp fetch_nodes!(client, parent_ids, include_children, verbose) do
    Enum.reduce(parent_ids, [], fn root_id, acc ->
      Logger.log("Fetching page tree for root #{root_id}...", true)

      case Client.fetch_tree(client, root_id, include_children, verbose) do
        {:ok, fetched_nodes} ->
          acc ++ fetched_nodes

        {:error, reason} ->
          raise reason
      end
    end)
  end

  defp build_page_lookup(page_nodes) do
    Enum.reduce(page_nodes, %{}, fn page, acc ->
      Map.put(acc, {page.root_parent_id, page.id}, page)
    end)
  end

  defp sync_pages(page_nodes, client, pages_by_root_and_id, verbose, summary) do
    Enum.reduce(page_nodes, summary, fn page, summary_acc ->
      Logger.log("Converting page #{page.id} (#{page.title}) to Markdown...", verbose)

      html =
        case Client.convert_storage_to_export_view(client, page.id, page.storage_value) do
          {:ok, export_view_html} ->
            export_view_html

          {:error, reason} ->
            Logger.log("Falling back to storage HTML for page #{page.id}: #{reason}", true)
            page.storage_value
        end

      local_pages_by_id = pages_for_root(pages_by_root_and_id, page.root_parent_id)
      markdown_body = Markdown.from_html(html, page, local_pages_by_id)
      Writer.write_page(page, markdown_body, summary_acc)
    end)
  end

  defp pages_for_root(pages_by_root_and_id, root_parent_id) do
    Enum.reduce(pages_by_root_and_id, %{}, fn
      {{^root_parent_id, page_id}, page}, acc -> Map.put(acc, page_id, page)
      {_other_key, _page}, acc -> acc
    end)
  end

  defp target_value(target, key, default) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(target, key) ->
        Map.get(target, key)

      Map.has_key?(target, string_key) ->
        Map.get(target, string_key)

      true ->
        default
    end
  end

  defp normalize_boolean!(value, _key_name, _config) when is_boolean(value), do: value

  defp normalize_boolean!(value, key_name, config) do
    raise "Expected #{key_name} to be a boolean in #{config.config_file_name}, got: #{inspect(value)}"
  end

  defp ensure_page_target!(target, config) do
    type = target_value(target, :type, "page") |> to_string() |> String.downcase()

    if type != "page" do
      raise "Space sync has been removed. Please use only page targets in #{config.config_file_name}."
    end
  end

  defp reset_directory!(path) do
    File.rm_rf!(path)
    File.mkdir_p!(path)
  end

  defp ensure_config!(config) do
    cond do
      not config.config_file_exists? ->
        raise """
        Missing config file: #{config.config_file_path}

        Create it next to sync_confluence.exs. You can start from:
        #{config.example_config_file_path}
        """

      config.confluence_base_url in ["", "https://your-site.atlassian.net"] ->
        raise "Please set confluence_base_url in #{config.config_file_name}."

      config.confluence_email in ["", "you@example.com"] ->
        raise "Please set confluence_email in #{config.config_file_name}."

      config.confluence_api_token in ["", "replace-me"] ->
        raise "Please set confluence_api_token in #{config.config_file_name}."

      true ->
        :ok
    end
  end

  defp child_page_setting(opts, config) do
    cond do
      opts[:with_children] -> true
      opts[:without_children] -> false
      true -> config.sync_child_pages
    end
  end

  defp usage(config) do
    IO.puts("""
    Usage:
      elixir sync_confluence.exs --parent <url-or-page-id> [--parent <url-or-page-id> ...] [--out <dir>] [--with-children|--without-children] [--verbose]

    Config file:
      #{config.config_file_path}

    Defaults:
      local_sync_dir   #{config.local_sync_dir}
      child_pages      #{config.sync_child_pages}

    Notes:
      - Put credentials and defaults into #{config.config_file_name}, next to this script.
      - You can start from #{Path.basename(config.example_config_file_path)}.
      - Define multiple configured sync targets via sync_targets in the config file.
      - Each target supports source, output_dir, and include_children.
      - include_children walks nested subpages recursively, not just direct children.
      - Edit local_sync_dir in the config file to choose the local sync folder.
      - local_sync_dir is resolved relative to the directory where you run the script.
      - Confluence folders are mirrored as local directories; pages are written as Markdown files inside them.
      - Page-to-page nesting stays flat within the current folder path, no index.md structure.
      - Page links inside the synced subtree are rewritten to relative Markdown paths.
      - The whole output directory is cleared before each sync run so stale files do not remain behind.
    """)
  end
end

SyncConfluence.main(config, System.argv())
