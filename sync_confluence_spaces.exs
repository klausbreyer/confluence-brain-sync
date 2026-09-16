Mix.install([
  {:req, "~> 0.5"},
  {:floki, "~> 0.37"}
])

config_file_name = "sync_confluence_spaces.local.exs"
script_dir = __ENV__.file |> Path.expand() |> Path.dirname()
config_file_path = Path.join(script_dir, config_file_name)
example_config_file_path = Path.join(script_dir, "sync_confluence_spaces.local.example.exs")

raw_config =
  cond do
    File.exists?(config_file_path) ->
      case Code.eval_file(config_file_path) do
        {%{} = map, _binding} ->
          map

        {list, _binding} when is_list(list) ->
          Map.new(list)

        {other, _binding} ->
          raise "Expected #{config_file_name} to return a map or keyword list, got: #{inspect(other)}"
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
  confluence_base_url:
    fetch_config.(:confluence_base_url, "https://your-site.atlassian.net")
    |> to_string()
    |> String.trim_trailing("/"),
  confluence_email:
    fetch_config.(:confluence_email, "you@example.com") |> to_string() |> String.trim(),
  confluence_api_token:
    fetch_config.(:confluence_api_token, "replace-me") |> to_string() |> String.trim(),
  local_sync_dir: fetch_config.(:local_sync_dir, "./confluence") |> to_string(),
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
    |> String.replace(~r/^[. ]+|[. ]+$/u, "")
    |> case do
      "" -> "Untitled"
      stem -> stem
    end
  end

  def parse_space_key(value) when is_binary(value) do
    value = String.trim(value)
    uri = URI.parse(value)

    key =
      if uri.scheme in ["http", "https"] and uri.host do
        case Regex.run(~r{^/wiki/spaces/([^/]+)(?:/overview)?/?$}, uri.path || "") do
          [_, key] -> URI.decode(key)
          _ -> nil
        end
      else
        value
      end

    if is_binary(key) and String.match?(key, ~r/^[A-Za-z0-9_~.-]+$/) and key not in [".", ".."] do
      {:ok, key}
    else
      {:error, "Expected a Confluence space key or space overview URL, got: #{inspect(value)}."}
    end
  end

  def parse_space_key(value) do
    {:error, "Expected a Confluence space key or space overview URL, got: #{inspect(value)}."}
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
    from_parts = from_path |> Path.dirname() |> Path.split()
    to_parts = Path.split(to_path)
    {from_rest, to_rest} = drop_common_path(from_parts, to_parts)
    Path.join(List.duplicate("..", length(from_rest)) ++ to_rest)
  end

  defp drop_common_path([part | from], [part | to]), do: drop_common_path(from, to)
  defp drop_common_path(from, to), do: {from, to}

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
        if String.downcase(header_name) == normalized_name,
          do: List.first(List.wrap(value)),
          else: nil

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

  @page_body_fetch_concurrency 16

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

  def fetch_space_target_tree(client, target, verbose) do
    space = target.space

    with {:ok, listed_pages} <-
           paginate_json(
             client,
             "/wiki/api/v2/spaces/#{space["id"]}/pages",
             [limit: 250, depth: "all", status: "current"],
             verbose
           ) do
      page_ids = listed_pages |> Enum.map(& &1["id"]) |> Enum.uniq()
      Logger.log("Space #{target.space_key}: fetching #{length(page_ids)} page bodies...", true)

      case fetch_pages_map(client, page_ids, verbose, allow_missing: true) do
        {:error, reason} ->
          {:error, reason}

        pages ->
          with {:ok, nodes} <- fetch_parent_containers(client, pages, MapSet.new()) do
            adjusted_nodes =
              nodes
              |> Map.values()
              |> Enum.map(fn node ->
                parent_id =
                  if Map.has_key?(nodes, node.parent_id), do: node.parent_id, else: target.id

                node
                |> Map.put(:root_parent_id, target.id)
                |> Map.put(:parent_id, parent_id)
              end)

            {:ok, [target_root_node(target) | adjusted_nodes]}
          end
      end
    end
  end

  def fetch_space(client, key, verbose) do
    with {:ok, spaces} <-
           paginate_json(client, "/wiki/api/v2/spaces", [keys: key, limit: 250], verbose) do
      # Renamed spaces keep their original key; URLs use the current alias.
      case Enum.find(spaces, &(&1["key"] == key or &1["currentActiveAlias"] == key)) do
        nil -> {:error, "Space #{key} was not found or is not accessible with these credentials."}
        space -> {:ok, space}
      end
    end
  end

  # Space page listings include all depths. Only non-page ancestors need extra
  # requests to preserve folders and other containers between those pages.
  defp fetch_parent_containers(client, nodes, attempted) do
    parents =
      nodes
      |> Map.values()
      |> Enum.filter(fn node ->
        node.parent_id not in [nil, ""] and
          node.parent_type in ["folder", "database", "embed", "whiteboard"] and
          not Map.has_key?(nodes, node.parent_id) and
          not MapSet.member?(attempted, node.parent_id)
      end)
      |> Enum.uniq_by(& &1.parent_id)

    if parents == [] do
      {:ok, nodes}
    else
      attempted = Enum.reduce(parents, attempted, &MapSet.put(&2, &1.parent_id))

      result =
        parents
        |> Task.async_stream(
          fn node -> fetch_container(client, node.parent_type, node.parent_id) end,
          max_concurrency: @page_body_fetch_concurrency,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.reduce_while({:ok, nodes}, fn
          {:ok, {:ok, container}}, {:ok, acc} ->
            {:cont, {:ok, Map.put(acc, container.id, container)}}

          {:ok, {:error, reason}}, {:ok, acc} ->
            if missing_page_error?(reason) do
              Logger.log("Skipping missing or inaccessible container: #{reason}", true)
              {:cont, {:ok, acc}}
            else
              {:halt, {:error, reason}}
            end

          {:exit, reason}, _acc ->
            {:halt, {:error, "Container fetch task failed: #{inspect(reason)}"}}
        end)

      with {:ok, nodes} <- result do
        fetch_parent_containers(client, nodes, attempted)
      end
    end
  end

  defp fetch_container(client, type, id) do
    case request_json(client, :get, "/wiki/api/v2/#{type}s/#{id}") do
      {:ok, body, _response} ->
        {:ok, normalize_node(body, type)}

      {:error, reason} ->
        {:error, "Could not fetch #{type} #{id}: #{reason}"}
    end
  end

  defp normalize_node(body, type) do
    %{
      id: body["id"],
      type: type,
      title: body["title"] || "#{String.capitalize(type)} #{body["id"]}",
      parent_id: body["parentId"],
      source_parent_id: body["parentId"],
      parent_type: body["parentType"],
      child_position: body["position"] || 0,
      space_id: body["spaceId"]
    }
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
         Map.merge(normalize_node(body, "page"), %{
           version: get_in(body, ["version", "number"]),
           storage_value: get_in(body, ["body", "storage", "value"]) || "",
           source_url: source_url(client.base_url, body["id"], body["_links"] || %{})
         })}

      {:error, reason} ->
        {:error, "Could not fetch page #{page_id}: #{reason}"}
    end
  end

  defp fetch_pages_map(client, page_ids, _verbose, opts) do
    allow_missing = Keyword.get(opts, :allow_missing, false)

    page_ids
    |> Task.async_stream(
      fn page_id ->
        {page_id, fetch_page(client, page_id)}
      end,
      max_concurrency: @page_body_fetch_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce_while(%{}, fn
      {:ok, {page_id, {:ok, page}}}, acc ->
        {:cont, Map.put(acc, page_id, page)}

      {:ok, {page_id, {:error, reason}}}, acc ->
        if allow_missing and missing_page_error?(reason) do
          Logger.log("Skipping missing or inaccessible page #{page_id}: #{reason}", true)
          {:cont, acc}
        else
          {:halt, {:error, reason}}
        end

      {:exit, reason}, _acc ->
        {:halt, {:error, "Page fetch task failed: #{inspect(reason)}"}}
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

  defp do_paginate_json(client, url, params, verbose, acc) do
    case request_json(client, :get, url, params: params) do
      {:ok, %{"results" => results} = body, _response} ->
        Logger.log("Fetched #{length(results)} items from #{url}.", verbose)

        case get_in(body, ["_links", "next"]) do
          next when is_binary(next) and next != "" ->
            next_url = client.base_url |> URI.merge(url) |> URI.merge(next) |> to_string()
            do_paginate_json(client, next_url, [], verbose, [results | acc])

          _ ->
            {:ok, [results | acc] |> Enum.reverse() |> List.flatten()}
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
        nil ->
          backoff_ms(retries_left)

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
        path = if String.starts_with?(path, "/spaces/"), do: "/wiki" <> path, else: path
        URI.merge(base_url, path) |> to_string()

      _ ->
        "#{base_url}/wiki/pages/viewpage.action?pageId=#{page_id}"
    end
  end

  defp target_root_node(target) do
    %{
      id: target.id,
      type: "space",
      title: target.space["name"] || target.space_key,
      parent_id: nil,
      root_parent_id: target.id,
      homepage_id: target.space["homepageId"],
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

    nodes_with_dirs =
      roots
      |> Enum.flat_map(fn root ->
        root_nodes = Map.fetch!(nodes_by_root, root.id)
        assign_paths_for_root(root, root_nodes, root.output_dir)
      end)

    page_paths =
      nodes_with_dirs
      |> Enum.filter(&(&1.type == "page"))
      |> Enum.group_by(& &1.relative_dir)
      |> Enum.flat_map(fn {relative_dir, pages} ->
        {container_pages, leaf_pages} = Enum.split_with(pages, &page_container?/1)
        leaf_file_names = assign_page_file_names(leaf_pages)

        container_page_paths =
          Enum.map(container_pages, fn page ->
            {page.id, maybe_join(page.relative_dir, "index.md")}
          end)

        leaf_page_paths =
          Enum.map(leaf_pages, fn page ->
            {page.id, maybe_join(relative_dir, Map.fetch!(leaf_file_names, page.id))}
          end)

        container_page_paths ++ leaf_page_paths
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

  def space_directory_names(targets) do
    targets
    |> Enum.map(fn target ->
      %{id: target.space["id"], title: target.space["name"] || target.space_key}
    end)
    |> assign_directory_names([])
  end

  defp assign_paths_for_root(root, root_nodes, root_dir) do
    homepage = Enum.find(root_nodes, &(&1.type == "page" and &1.id == root.homepage_id))
    homepage_id = if homepage, do: homepage.id

    # The homepage is the space's index. Its children and other top-level pages
    # share the space directory, including the same filename collision checks.
    children_by_parent =
      root_nodes
      |> Enum.reject(&(&1.id == root.id or &1.id == homepage_id))
      |> Enum.group_by(fn node ->
        if homepage && node.parent_id == homepage_id, do: root.id, else: node.parent_id
      end)

    root_with_paths =
      root
      |> Map.put(:relative_dir, root_dir)
      |> Map.put(:is_container, true)
      |> Map.put(:relative_path, root_dir)

    homepage_nodes =
      if homepage do
        [homepage |> Map.put(:relative_dir, root_dir) |> Map.put(:is_container, true)]
      else
        []
      end

    [root_with_paths | homepage_nodes ++ assign_child_paths(root, children_by_parent, root_dir)]
  end

  defp assign_child_paths(parent, children_by_parent, current_dir) do
    children =
      children_by_parent
      |> Map.get(parent.id, [])
      |> Enum.sort_by(&{&1.child_position || 0, &1.title || "", &1.id})

    leaf_file_names =
      children
      |> Enum.filter(&(&1.type == "page" and not Map.has_key?(children_by_parent, &1.id)))
      |> assign_page_file_names()
      |> Map.values()

    directory_names =
      children
      |> Enum.filter(&(folder_type?(&1) or Map.has_key?(children_by_parent, &1.id)))
      |> assign_directory_names(["index.md" | leaf_file_names])

    Enum.flat_map(children, fn child ->
      cond do
        child.type == "page" ->
          child_has_children? = Map.has_key?(children_by_parent, child.id)

          page_dir =
            page_directory(current_dir, parent, child, child_has_children?, directory_names)

          page =
            child
            |> Map.put(:relative_dir, page_dir)
            |> Map.put(:is_container, child_has_children?)
            |> Map.put(:relative_path, page_dir)

          [page | assign_child_paths(page, children_by_parent, page_dir)]

        folder_type?(child) ->
          folder_dir = maybe_join(current_dir, Map.fetch!(directory_names, child.id))

          folder =
            child
            |> Map.put(:relative_dir, folder_dir)
            |> Map.put(:is_container, true)
            |> Map.put(:relative_path, folder_dir)

          [folder | assign_child_paths(folder, children_by_parent, folder_dir)]

        true ->
          assign_child_paths(child, children_by_parent, current_dir)
      end
    end)
  end

  defp assign_page_file_names(pages) do
    pages
    |> Enum.map(fn page ->
      {page.id, Util.safe_file_stem(page.title)}
    end)
    |> assign_unique_names(
      fn stem, _id -> "#{stem}.md" end,
      fn stem, id -> "#{stem} (#{id}).md" end,
      ["index.md"]
    )
  end

  defp assign_directory_names(nodes, reserved) do
    nodes
    |> Enum.map(fn node ->
      {node.id, Util.safe_file_stem(node.title)}
    end)
    |> assign_unique_names(
      fn stem, _id -> stem end,
      fn stem, id -> "#{stem} (#{id})" end,
      reserved
    )
  end

  defp assign_unique_names(base_names, unique_name_fun, duplicate_name_fun, reserved) do
    counts = Enum.frequencies_by(base_names, fn {_id, stem} -> name_key(stem) end)
    reserved = MapSet.new(reserved, &name_key/1)

    # Reserve natural names before adding ID suffixes, so generated names cannot
    # overwrite another page whose title already includes that suffix.
    used =
      Enum.reduce(base_names, reserved, fn {id, stem}, acc ->
        MapSet.put(acc, name_key(unique_name_fun.(stem, id)))
      end)

    base_names
    |> Enum.sort()
    |> Enum.reduce({%{}, used}, fn {id, stem}, {names, used} ->
      natural_name = unique_name_fun.(stem, id)

      name =
        if counts[name_key(stem)] > 1 or MapSet.member?(reserved, name_key(natural_name)) do
          Stream.iterate(1, &(&1 + 1))
          |> Enum.find_value(fn attempt ->
            suffix = if attempt == 1, do: id, else: "#{id}-#{attempt}"
            candidate = duplicate_name_fun.(stem, suffix)
            if not MapSet.member?(used, name_key(candidate)), do: candidate
          end)
        else
          natural_name
        end

      {Map.put(names, id, name), MapSet.put(used, name_key(name))}
    end)
    |> elem(0)
  end

  defp name_key(name), do: name |> String.normalize(:nfc) |> String.downcase()

  defp folder_type?(node) do
    node.type in ["folder", "database", "embed", "whiteboard"]
  end

  defp page_container?(page) do
    Map.get(page, :is_container, false)
  end

  defp page_directory(current_dir, _parent, _page, false, _directory_names), do: current_dir

  defp page_directory(current_dir, _parent, page, true, directory_names) do
    maybe_join(current_dir, Map.fetch!(directory_names, page.id))
  end

  defp maybe_join("", file_name), do: file_name
  defp maybe_join(relative_dir, file_name), do: Path.join(relative_dir, file_name)
end

defmodule SyncConfluence.Markdown do
  alias SyncConfluence.Util

  def from_html(html, current_page, local_pages_by_id) do
    {:ok, nodes} = Floki.parse_fragment(html)

    nodes
    |> Enum.map(
      &render_node(&1, %{page: current_page, pages_by_id: local_pages_by_id, list_depth: 0})
    )
    |> Enum.join()
    |> postprocess_markdown()
  end

  defp render_node(text, _ctx) when is_binary(text) do
    text
    |> String.replace(~r/\s+/u, " ")
  end

  defp render_node({"br", _attrs, _children}, _ctx), do: "  \n"
  defp render_node({"hr", _attrs, _children}, _ctx), do: "\n\n---\n\n"

  defp render_node({"h" <> level, _attrs, children}, ctx)
       when level in ["1", "2", "3", "4", "5", "6"] do
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
       when tag in [
              "div",
              "span",
              "section",
              "article",
              "main",
              "body",
              "html",
              "header",
              "footer",
              "nav"
            ] do
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

        relative =
          Util.relative_link(ctx.page.relative_path, target.relative_path)
          |> URI.encode(fn char -> URI.char_unreserved?(char) or char == ?/ end)

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
      "parent_page_id" => if(page.parent_type == "page", do: page.source_parent_id, else: nil),
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

  @target_concurrency 8
  @page_conversion_concurrency 16

  def main(config, argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          out: :string,
          space: :keep,
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

    if args != [], do: raise("Unexpected argument(s): #{Enum.join(args, ", ")}")

    if opts[:help] do
      usage(config)
    else
      run_sync(config, opts)
    end
  end

  defp run_sync(config, opts) do
    ensure_config!(config)

    started_at = System.monotonic_time(:millisecond)
    verbose = Keyword.get(opts, :verbose, false)
    client = Client.new(config)
    targets = normalize_targets!(config, Keyword.get_values(opts, :space))
    output_dir = Path.expand(Keyword.get(opts, :out, config.local_sync_dir), File.cwd!())

    Logger.log(
      "Preparing sync for #{length(targets)} whole space(s), including all subpages...",
      true
    )

    Logger.log(
      "Sync concurrency: #{@target_concurrency} spaces, 16 page fetches and #{@page_conversion_concurrency} conversions per space",
      true
    )

    Logger.log("Local output directory: #{output_dir}", true)

    targets = resolve_spaces!(client, targets, verbose)
    reset_directory!(output_dir)
    summary = run_spaces_sync(client, targets, output_dir, verbose)

    IO.puts("")
    IO.puts("Sync complete.")
    IO.puts("Output directory: #{output_dir}")
    IO.puts("Written: #{summary.written}")
    IO.puts("Duration: #{format_duration(System.monotonic_time(:millisecond) - started_at)}")
  end

  defp resolve_spaces!(client, targets, verbose) do
    targets =
      targets
      |> Task.async_stream(
        fn target ->
          case Client.fetch_space(client, target.space_key, verbose) do
            {:ok, space} -> {:ok, Map.put(target, :space, space)}
            {:error, reason} -> {:error, reason}
          end
        end,
        max_concurrency: @target_concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, {:ok, target}} -> target
        {:ok, {:error, reason}} -> raise reason
        {:exit, reason} -> raise "Space lookup task failed: #{inspect(reason)}"
      end)
      |> Enum.uniq_by(& &1.space["id"])

    directory_names = Tree.space_directory_names(targets)

    Enum.map(targets, fn target ->
      Map.put(target, :output_dir, Map.fetch!(directory_names, target.space["id"]))
    end)
  end

  defp run_spaces_sync(client, targets, output_dir, verbose) do
    targets
    |> Task.async_stream(
      fn target ->
        started_at = System.monotonic_time(:millisecond)
        Logger.log("Space #{target.space_key} -> #{target.output_dir}", true)

        case Client.fetch_space_target_tree(client, target, verbose) do
          {:ok, nodes} ->
            summary = sync_target_nodes(nodes, output_dir, client, verbose, %{written: 0})
            duration = format_duration(System.monotonic_time(:millisecond) - started_at)

            Logger.log(
              "Space #{target.space_key}: #{summary.written} pages written in #{duration}.",
              true
            )

            {:ok, summary}

          {:error, reason} ->
            {:error, "Space #{target.space_key}: #{reason}"}
        end
      end,
      max_concurrency: @target_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce(%{written: 0}, fn
      {:ok, {:ok, target_summary}}, summary_acc ->
        merge_summary(summary_acc, target_summary)

      {:ok, {:error, reason}}, _summary_acc ->
        raise reason

      {:exit, reason}, _summary_acc ->
        raise "Space sync task failed: #{inspect(reason)}"
    end)
  end

  defp sync_target_nodes(nodes, output_dir, client, verbose, summary) do
    enriched_nodes = Tree.enrich_paths(nodes, output_dir)
    container_nodes = Enum.filter(enriched_nodes, fn node -> node.type != "page" end)
    page_nodes = Enum.filter(enriched_nodes, fn node -> node.type == "page" end)
    pages_by_root_and_id = build_page_lookup(page_nodes)
    summary = Enum.reduce(container_nodes, summary, &Writer.ensure_container/2)

    sync_pages(page_nodes, client, pages_by_root_and_id, verbose, summary)
  end

  defp normalize_targets!(config, cli_spaces) do
    sources = if cli_spaces == [], do: config.sync_targets, else: cli_spaces

    if not is_list(sources) or sources == [] do
      raise "Define spaces in sync_targets in #{config.config_file_name} or pass --space on the command line."
    end

    sources |> Enum.map(&normalize_target!/1) |> Enum.uniq_by(& &1.space_key)
  end

  defp normalize_target!(source) when is_binary(source), do: normalize_target!(%{source: source})
  defp normalize_target!(target) when is_list(target), do: normalize_target!(Map.new(target))

  defp normalize_target!(%{} = target) do
    source = target_value(target, :source, nil)

    if target_value(target, :type, "space") not in ["space", :space] or
         target_value(target, :include_children, true) != true do
      raise "Sync targets must be whole spaces. All subpages are always included."
    end

    space_key =
      case Util.parse_space_key(source) do
        {:ok, key} -> key
        {:error, reason} -> raise reason
      end

    %{
      id: "space:#{space_key}",
      source: source,
      space_key: space_key
    }
  end

  defp normalize_target!(target), do: raise("Invalid space target: #{inspect(target)}")

  defp build_page_lookup(page_nodes) do
    Enum.reduce(page_nodes, %{}, fn page, acc ->
      # Link rewriting only needs paths. Keep all page bodies out of each task's lookup.
      Map.put(acc, {page.root_parent_id, page.id}, %{relative_path: page.relative_path})
    end)
  end

  defp sync_pages(page_nodes, client, pages_by_root_and_id, verbose, summary) do
    pages_by_root = pages_by_root_lookup(pages_by_root_and_id)

    page_nodes
    |> Task.async_stream(
      fn page ->
        Logger.log("Converting page #{page.id} (#{page.title}) to Markdown...", verbose)

        html =
          case Client.convert_storage_to_export_view(client, page.id, page.storage_value) do
            {:ok, export_view_html} ->
              export_view_html

            {:error, reason} ->
              Logger.log("Falling back to storage HTML for page #{page.id}: #{reason}", true)
              page.storage_value
          end

        local_pages_by_id = Map.get(pages_by_root, page.root_parent_id, %{})
        markdown_body = Markdown.from_html(html, page, local_pages_by_id)
        Writer.write_page(page, markdown_body, %{written: 0})
      end,
      max_concurrency: @page_conversion_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce(summary, fn
      {:ok, page_summary}, summary_acc ->
        merge_summary(summary_acc, page_summary)

      {:exit, reason}, _summary_acc ->
        raise "Page conversion task failed: #{inspect(reason)}"
    end)
  end

  defp pages_by_root_lookup(pages_by_root_and_id) do
    Enum.reduce(pages_by_root_and_id, %{}, fn {{root_parent_id, page_id}, page}, acc ->
      Map.update(acc, root_parent_id, %{page_id => page}, fn pages ->
        Map.put(pages, page_id, page)
      end)
    end)
  end

  defp merge_summary(summary, next_summary) do
    written = Map.get(next_summary, :written, 0)
    Map.update(summary, :written, written, &(&1 + written))
  end

  defp format_duration(milliseconds) do
    total_seconds = div(milliseconds, 1_000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60) + rem(milliseconds, 1_000) / 1_000

    if minutes > 0 do
      "#{minutes}m #{:erlang.float_to_binary(seconds, decimals: 2)}s"
    else
      "#{:erlang.float_to_binary(seconds, decimals: 2)}s"
    end
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

  defp reset_directory!(path) do
    if path == File.cwd!() or String.starts_with?(File.cwd!(), path <> "/") or path == "/" do
      raise "The sync output directory must not contain the working directory."
    end

    File.rm_rf!(path)
    File.mkdir_p!(path)
  end

  defp ensure_config!(config) do
    cond do
      not config.config_file_exists? ->
        raise """
        Missing config file: #{config.config_file_path}

        Create it next to sync_confluence_spaces.exs. You can start from:
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

  defp usage(config) do
    IO.puts("""
    Usage:
      elixir sync_confluence_spaces.exs [--space <space-url-or-key> ...] [--out <dir>] [--verbose]

    Config file:
      #{config.config_file_path}

    Defaults:
      local_sync_dir   #{config.local_sync_dir}

    Notes:
      - Put credentials and defaults into #{config.config_file_name}, next to this script.
      - You can start from #{Path.basename(config.example_config_file_path)}.
      - Define sync_targets as space URLs/keys or maps with source.
      - Each space gets one folder named after its full Confluence name, directly inside the output.
      - The space homepage is index.md in that folder, without an extra homepage directory.
      - Older output_dir settings in sync_targets are ignored; no config migration is needed.
      - --space replaces configured targets; repeat it to sync multiple spaces.
      - All accessible current pages are included, at every depth and outside the homepage tree.
      - Personal space URLs work too; homepageId and other query parameters are ignored.
      - Confluence folders containing pages are mirrored as local directories.
      - Pages with children use a directory with index.md; leaf pages use <title>.md.
      - Page links within each space are rewritten to relative Markdown paths.
      - --out overrides local_sync_dir for both configured spaces and CLI spaces.
      - The output path is relative to the directory where you run the script.
      - The whole output directory is cleared before each sync. Use --out ./tmp/space-test to test.
      - Up to 8 spaces run concurrently, with 16 body fetches and 16 conversions per space.
      - Page counts and durations are printed per space and for the complete run.
    """)
  end
end

SyncConfluence.main(config, System.argv())
