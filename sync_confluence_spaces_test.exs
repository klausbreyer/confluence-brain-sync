ExUnit.start()

# Load the standalone script through its read-only help entry point.
original_argv = System.argv()
System.argv(["--help"])
ExUnit.CaptureIO.capture_io(fn -> Code.require_file("sync_confluence_spaces.exs", __DIR__) end)
System.argv(original_argv)

defmodule SyncConfluenceTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias SyncConfluence.{Client, Util}

  @private_key "~712020e2d192065fec4c0e90ea115757a438c4"

  setup do
    output =
      Path.join(System.tmp_dir!(), "confluence-spaces-#{System.unique_integer([:positive])}")

    old_options = Req.default_options()

    # No request from these tests may reach Confluence.
    Req.default_options(
      adapter: fn request -> raise "Unexpected request: #{request.url}" end,
      retry: false
    )

    on_exit(fn ->
      Req.default_options(old_options)
      File.rm_rf!(output)
    end)

    config = %{
      confluence_base_url: "https://confluence.test",
      confluence_email: "test@example.test",
      confluence_api_token: "test-token",
      local_sync_dir: output,
      sync_targets: [],
      config_file_exists?: true,
      config_file_name: "sync_confluence_spaces.local.exs"
    }

    {:ok, config: config, output: output}
  end

  test "accepts every example space URL, encoded personal keys, and bare keys" do
    for key <- ["PED", "FFP", "myoformfix", @private_key, "MYO"] do
      assert Util.parse_space_key(key) == {:ok, key}

      assert Util.parse_space_key("https://myosotis.atlassian.net/wiki/spaces/#{key}/overview") ==
               {:ok, key}
    end

    assert Util.parse_space_key(
             "https://myosotis.atlassian.net/wiki/spaces/#{@private_key}/overview?homepageId=3727524416"
           ) == {:ok, @private_key}

    assert Util.parse_space_key(
             "https://myosotis.atlassian.net/wiki/spaces/MYO/overview?xpis=eyJicmlkZ2UiOiJxdWlja0ZpbmQiLCJpZCI6IjE3ODg5NTUzNjgzNzYiLCJzb3VyY2UiOiJjb25mbHVlbmNlIn0%3D"
           ) == {:ok, "MYO"}

    assert Util.parse_space_key("https://example.test/wiki/spaces/%7Eprivate/overview/") ==
             {:ok, "~private"}

    for source <- ["", nil, "../PED", "https://example.test/wiki/spaces/PED/pages/123/Title"] do
      assert {:error, _} = Util.parse_space_key(source)
    end
  end

  test "exports all roots, nested pages and containers across pagination without duplicate space and homepage folders",
       %{config: config, output: output} do
    pages = [
      page("1", "Home"),
      page("2", "Child", "1"),
      page("3", "Other root"),
      page("4", "Nested", "3"),
      page("5", "Deep", "11", "folder"),
      page("6", "index", "1"),
      page("7", "Peer", "11", "folder"),
      page("8", "Beyond whiteboard", "12", "whiteboard"),
      page("9", "Notes", "1"),
      page("10", "notes", "1")
    ]

    pages_by_id = Map.new(pages, &{&1["id"], &1})

    containers = %{
      "11" => container("11", "Inner", "13", "folder"),
      "13" => container("13", "Outer", "1", "page"),
      "12" => container("12", "Board", "14", "database"),
      "14" => container("14", "Database", "15", "embed"),
      "15" => container("15", "Link", nil, nil)
    }

    {:ok, requests} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(requests), do: Agent.stop(requests) end)

    stub(fn request ->
      path = request.url.path
      query = URI.decode_query(request.url.query || "")
      Agent.update(requests, &[{request.method, path, query} | &1])

      body =
        case {request.method, path} do
          {:get, "/wiki/api/v2/spaces"} ->
            {name, homepage_id} =
              if query["keys"] == "PED",
                do: {"Product Engineering & Design", "1"},
                else: {"Private space", "20"}

            results([
              %{
                "id" => query["keys"],
                "key" => query["keys"],
                "name" => name,
                "homepageId" => homepage_id
              }
            ])

          {:get, "/wiki/api/v2/spaces/PED/pages"} ->
            if query["cursor"] == "second" do
              results(Enum.drop(pages, 3))
            else
              assert query["depth"] == "all"
              assert query["limit"] == "250"
              assert query["status"] == "current"
              results(Enum.take(pages, 3), "?cursor=second")
            end

          {:get, "/wiki/api/v2/spaces/" <> _} ->
            results([page("20", "Private home")])

          {:get, "/wiki/api/v2/pages/20"} ->
            page("20", "Private home")

          {:get, "/wiki/api/v2/pages/" <> id} ->
            Map.fetch!(pages_by_id, id)

          {:post, "/wiki/rest/api/contentbody/convert/async/export_view"} ->
            %{"asyncId" => query["contentIdContext"]}

          {:get, "/wiki/rest/api/contentbody/convert/async/2"} ->
            %{"value" => ~s(<p><a href="/wiki/spaces/PED/pages/4/Nested#section">Other</a></p>)}

          {:get, "/wiki/rest/api/contentbody/convert/async/" <> id} ->
            %{"value" => "<p>Exported #{id}</p>"}

          {:get, "/wiki/api/v2/" <> rest} ->
            [_type, id] = String.split(rest, "/")
            Map.fetch!(containers, id)
        end

      {200, body}
    end)

    config = %{
      config
      | sync_targets: ["PED", %{"source" => @private_key, "output_dir" => "Privat"}]
    }

    File.mkdir_p!(output)
    File.write!(Path.join(output, "keep.txt"), "Existing export")
    trial = Path.join(output, "trial")
    log = capture_io(fn -> SyncConfluence.main(config, ["--out", trial]) end)

    expected = %{
      "Product Engineering & Design/index.md" => "1",
      "Product Engineering & Design/Child.md" => "2",
      "Product Engineering & Design/Other root/index.md" => "3",
      "Product Engineering & Design/Other root/Nested.md" => "4",
      "Product Engineering & Design/Outer/Inner/Deep.md" => "5",
      "Product Engineering & Design/index (6).md" => "6",
      "Product Engineering & Design/Outer/Inner/Peer.md" => "7",
      "Product Engineering & Design/Link/Database/Board/Beyond whiteboard.md" => "8",
      "Product Engineering & Design/Notes (9).md" => "9",
      "Product Engineering & Design/notes (10).md" => "10",
      "Private space/index.md" => "20"
    }

    actual =
      Path.wildcard(Path.join(trial, "**/*.md"))
      |> Enum.map(&Path.relative_to(&1, trial))
      |> Enum.sort()

    assert actual == expected |> Map.keys() |> Enum.sort()

    for {path, id} <- expected do
      markdown = File.read!(Path.join(trial, path))
      assert markdown =~ ~s(confluence_page_id: "#{id}")

      assert markdown =~
               if(id == "2",
                 do: "[Other](Other%20root/Nested.md#section)",
                 else: "Exported #{id}"
               )
    end

    assert File.read!(Path.join(trial, "Product Engineering & Design/index.md")) =~
             "https://confluence.test/wiki/spaces/PED/pages/1"

    assert File.read!(Path.join(output, "keep.txt")) == "Existing export"
    assert log =~ "Written: 11"
    assert log =~ "Space PED: 10 pages written in"
    assert log =~ "Duration:"
    calls = Agent.get(requests, & &1)
    assert Enum.count(calls, fn {_, path, _} -> path == "/wiki/api/v2/folders/11" end) == 1
  end

  test "equal space names and homepage children colliding with other roots preserve every page",
       %{
         config: config,
         output: output
       } do
    stub(fn request ->
      case request.url.path do
        "/wiki/api/v2/spaces" ->
          key = URI.decode_query(request.url.query)["keys"]
          id = if key == "PED", do: "100", else: "200"

          {200,
           results([%{"id" => id, "key" => key, "name" => "Shared", "homepageId" => id <> "1"}])}

        "/wiki/api/v2/spaces/" <> rest ->
          [space_id, "pages"] = String.split(rest, "/")
          {200, results(Enum.map(1..3, &%{"id" => space_id <> to_string(&1)}))}

        "/wiki/api/v2/pages/" <> id ->
          case String.last(id) do
            "1" -> {200, page(id, "Different homepage name")}
            "2" -> {200, page(id, "Guide", String.slice(id, 0..2) <> "1")}
            "3" -> {200, page(id, "Guide")}
          end

        "/wiki/rest/api/contentbody/convert/async/export_view" ->
          {200, %{"asyncId" => URI.decode_query(request.url.query)["contentIdContext"]}}

        "/wiki/rest/api/contentbody/convert/async/" <> id ->
          {200, %{"value" => "<p>Page #{id}</p>"}}
      end
    end)

    capture_io(fn ->
      SyncConfluence.main(
        %{
          config
          | sync_targets: [
              %{source: "PED", output_dir: "../old-setting"},
              %{source: "FFP", output_dir: "../old-setting"}
            ]
        },
        []
      )
    end)

    assert Enum.sort(File.ls!(output)) == ["Shared (100)", "Shared (200)"]

    for space_id <- ["100", "200"] do
      directory = Path.join(output, "Shared (#{space_id})")
      assert File.read!(Path.join(directory, "index.md")) =~ "Page #{space_id}1"
      assert File.read!(Path.join(directory, "Guide (#{space_id}2).md")) =~ "Page #{space_id}2"
      assert File.read!(Path.join(directory, "Guide (#{space_id}3).md")) =~ "Page #{space_id}3"
      assert length(File.ls!(directory)) == 3
    end
  end

  test "page and folder names cannot overwrite each other or a generated index", %{
    config: config,
    output: output
  } do
    pages = [
      page("1", "Home"),
      page("2", "index", "1"),
      page("3", "index (2)", "1"),
      page("4", "Docs", "1"),
      page("5", "Nested", "50", "folder"),
      page("6", "More", "60", "folder")
    ]

    stub(fn request ->
      case request.url.path do
        "/wiki/api/v2/spaces" -> {200, results([%{"id" => "s", "key" => "PED"}])}
        "/wiki/api/v2/spaces/s/pages" -> {200, results(pages)}
        "/wiki/api/v2/pages/" <> id -> {200, Enum.find(pages, &(&1["id"] == id))}
        "/wiki/api/v2/folders/50" -> {200, container("50", "Docs.md", "1", "page")}
        "/wiki/api/v2/folders/60" -> {200, container("60", "index.md", "1", "page")}
        "/wiki/rest/api/contentbody/convert/async/export_view" -> {400, %{}}
      end
    end)

    capture_io(fn -> SyncConfluence.main(%{config | sync_targets: ["PED"]}, []) end)

    for {path, id} <- [
          {"index.md", "1"},
          {"index (2-2).md", "2"},
          {"index (2).md", "3"},
          {"Docs.md", "4"},
          {"Docs.md (50)/Nested.md", "5"},
          {"index.md (60)/More.md", "6"}
        ] do
      assert File.read!(Path.join([output, "PED", "Home", path])) =~ "Storage #{id}"
    end
  end

  test "CLI spaces replace configured targets and duplicate spaces sync only once", %{
    config: config,
    output: output
  } do
    owner = self()

    stub(fn request ->
      case request.url.path do
        "/wiki/api/v2/spaces" ->
          key = URI.decode_query(request.url.query)["keys"]
          send(owner, {:space, key})
          {200, results([%{"id" => key, "key" => key}])}

        "/wiki/api/v2/spaces/" <> _ ->
          {200, results([])}
      end
    end)

    capture_io(fn ->
      SyncConfluence.main(%{config | sync_targets: ["UNUSED"]}, [
        "--space",
        "PED",
        "--space",
        "FFP",
        "--space",
        "PED"
      ])
    end)

    assert_receive {:space, "PED"}
    assert_receive {:space, "FFP"}
    refute_receive {:space, _}
    assert File.ls!(output) |> Enum.sort() == ["FFP", "PED"]
  end

  test "missing pages and containers do not hide accessible descendants", %{
    config: config,
    output: output
  } do
    stub(fn request ->
      case request.url.path do
        "/wiki/api/v2/spaces" ->
          {200, results([%{"id" => "s", "key" => "PED"}])}

        "/wiki/api/v2/spaces/s/pages" ->
          {200, results(Enum.map(1..3, &%{"id" => to_string(&1)}))}

        "/wiki/api/v2/pages/1" ->
          {404, %{"message" => "Not found"}}

        "/wiki/api/v2/pages/2" ->
          {200, page("2", "Survivor", "1")}

        "/wiki/api/v2/pages/3" ->
          {200, page("3", "Folder child", "99", "folder")}

        "/wiki/api/v2/folders/99" ->
          {404, %{"message" => "Not found"}}

        "/wiki/rest/api/contentbody/convert/async/export_view" ->
          {400, %{"message" => "Conversion unavailable"}}
      end
    end)

    log = capture_io(fn -> SyncConfluence.main(%{config | sync_targets: ["PED"]}, []) end)
    survivor = File.read!(Path.join(output, "PED/Survivor.md"))
    assert survivor =~ "Storage 2"
    assert survivor =~ ~s(parent_page_id: "1")
    assert File.read!(Path.join(output, "PED/Folder child.md")) =~ "Storage 3"
    assert log =~ "Skipping missing or inaccessible page 1"
    assert log =~ "Skipping missing or inaccessible container"
    assert log =~ "Written: 2"
  end

  test "renamed spaces resolve by active alias and use their stable ID", %{
    config: config,
    output: output
  } do
    stub(fn request ->
      case request.url.path do
        "/wiki/api/v2/spaces" ->
          assert URI.decode_query(request.url.query)["keys"] == "PED"

          {200,
           results([
             %{"id" => "other", "key" => "OTHER", "currentActiveAlias" => "OTHER"},
             %{"id" => "stable-id", "key" => "PTD", "currentActiveAlias" => "PED"}
           ])}

        "/wiki/api/v2/spaces/stable-id/pages" ->
          {200, results([page("1", "Home")])}

        "/wiki/api/v2/pages/1" ->
          {200, page("1", "Home")}

        "/wiki/rest/api/contentbody/convert/async/export_view" ->
          {200, %{"asyncId" => "1"}}

        "/wiki/rest/api/contentbody/convert/async/1" ->
          {200, %{"value" => "<p>Alias resolved</p>"}}
      end
    end)

    log = capture_io(fn -> SyncConfluence.main(%{config | sync_targets: ["PED"]}, []) end)
    assert File.read!(Path.join(output, "PED/Home.md")) =~ "Alias resolved"
    refute File.exists?(Path.join(output, "PTD"))
    assert log =~ "Written: 1"
  end

  test "unknown spaces and authorization errors fail explicitly", %{config: config} do
    stub(fn _request -> {200, results([])} end)
    assert {:error, reason} = Client.fetch_space(Client.new(config), "PED", false)
    assert reason =~ "not found or is not accessible"

    stub(fn _request -> {401, %{"message" => "Unauthorized"}} end)
    assert {:error, reason} = Client.fetch_space(Client.new(config), "PED", false)
    assert reason =~ "HTTP 401"
  end

  test "invalid page targets fail before clearing output", %{
    config: config,
    output: output
  } do
    File.mkdir_p!(output)
    marker = Path.join(output, "keep.txt")
    File.write!(marker, "Keep")

    for targets <- [
          [%{source: "PED", include_children: false}],
          ["https://confluence.test/wiki/spaces/PED/pages/1/Home"],
          []
        ] do
      assert_raise RuntimeError, fn ->
        SyncConfluence.main(%{config | sync_targets: targets}, [])
      end

      assert File.read!(marker) == "Keep"
    end

    assert_raise RuntimeError, ~r/Invalid option/, fn ->
      SyncConfluence.main(config, ["--parent", "123"])
    end
  end

  test "space discovery, page fetches and conversions retain their concurrency", %{config: config} do
    owner = self()

    stub(fn request ->
      query = URI.decode_query(request.url.query || "")

      case {request.method, request.url.path} do
        {:get, "/wiki/api/v2/spaces"} ->
          barrier(owner, :space)
          key = query["keys"]
          {200, results([%{"id" => key, "key" => key}])}

        {:get, "/wiki/api/v2/spaces/" <> _} ->
          {200, results(Enum.map(1..16, &%{"id" => to_string(&1)}))}

        {:get, "/wiki/api/v2/pages/" <> id} ->
          barrier(owner, :body)
          {200, page(id, "Page #{id}")}

        {:post, "/wiki/rest/api/contentbody/convert/async/export_view"} ->
          barrier(owner, :conversion)
          {200, %{"asyncId" => query["contentIdContext"]}}

        {:get, "/wiki/rest/api/contentbody/convert/async/" <> id} ->
          {200, %{"value" => "<p>#{id}</p>"}}
      end
    end)

    task =
      Task.async(fn ->
        capture_io(fn ->
          SyncConfluence.main(%{config | sync_targets: Enum.map(1..8, &"SPACE#{&1}")}, [])
        end)
      end)

    release_barrier(:space, 8)
    release_barrier(:body, 8 * 16)
    release_barrier(:conversion, 8 * 16)
    assert Task.await(task, 10_000) =~ "Written: 128"
  end

  test "rate limits honor Req's list-valued Retry-After header", %{config: config} do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    Req.default_options(
      retry: false,
      adapter: fn request ->
        attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})

        response =
          if attempt == 0,
            do: Req.Response.new(status: 429, headers: [{"retry-after", "1"}], body: %{}),
            else: Req.Response.new(status: 200, body: page("1", "Retry"))

        {request, response}
      end
    )

    assert {:ok, %{id: "1"}} = Client.fetch_page(Client.new(config), "1")
    assert Agent.get(attempts, & &1) == 2
    Agent.stop(attempts)
  end

  defp stub(handler) do
    Req.default_options(
      retry: false,
      adapter: fn request ->
        {status, body} = handler.(request)
        {request, Req.Response.new(status: status, body: body)}
      end
    )
  end

  defp results(items, next \\ nil), do: %{"results" => items, "_links" => %{"next" => next}}

  defp page(id, title, parent_id \\ nil, parent_type \\ "page") do
    %{
      "id" => id,
      "title" => title,
      "parentId" => parent_id,
      "parentType" => parent_type,
      "spaceId" => "s",
      "position" => 0,
      "version" => %{"number" => 1},
      "body" => %{"storage" => %{"value" => "<p>Storage #{id}</p>"}},
      "_links" => %{"webui" => "/spaces/PED/pages/#{id}"}
    }
  end

  defp container(id, title, parent_id, parent_type) do
    %{"id" => id, "title" => title, "parentId" => parent_id, "parentType" => parent_type}
  end

  # Hold requests until every expected slot is in flight. A serial regression
  # fails at the barrier, without relying on elapsed-time performance assertions.
  defp barrier(owner, phase) do
    send(owner, {phase, self()})

    receive do
      :continue -> :ok
    after
      10_000 -> raise "Concurrency barrier timed out: #{phase}"
    end
  end

  defp release_barrier(phase, count) do
    pids =
      for _ <- 1..count do
        receive do
          {^phase, pid} -> pid
        after
          5_000 -> flunk("Expected #{count} concurrent #{phase} requests")
        end
      end

    Enum.each(pids, &send(&1, :continue))
  end
end
