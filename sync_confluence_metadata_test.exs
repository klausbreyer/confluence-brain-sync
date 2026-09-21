ExUnit.start()

# Run each standalone script in its own VM because their module names overlap.
[script] = System.argv()
System.argv(["--help"])
ExUnit.CaptureIO.capture_io(fn -> Code.require_file(script, __DIR__) end)

defmodule SyncConfluenceMetadataTest do
  use ExUnit.Case, async: false
  alias SyncConfluence.{Client, Writer}

  setup do
    output =
      Path.join(System.tmp_dir!(), "confluence-metadata-#{System.unique_integer([:positive])}")

    old_options = Req.default_options()

    on_exit(fn ->
      Req.default_options(old_options)
      File.rm_rf!(output)
    end)

    config =
      %{
        confluence_base_url: "https://confluence.test",
        confluence_email: "test@example.test",
        confluence_api_token: "test-token",
        sync_concurrency: 2
      }

    body = %{
      "id" => "1",
      "title" => "Page",
      "spaceId" => "s",
      "parentType" => "page",
      "authorId" => "creator",
      "createdAt" => "2020-01-02T03:04:05.000Z",
      "version" => %{
        "number" => 7,
        "authorId" => "editor",
        "createdAt" => "2026-09-20T12:34:56.789Z"
      }
    }

    {:ok, config: config, body: body, output: output}
  end

  test "exports the original creator and source timestamps with YAML escaping", context do
    stub(
      context.body,
      {200, %{"results" => [%{"accountId" => "creator", "displayName" => "Ada \"L\": Example"}]}}
    )

    markdown = export(context)
    assert markdown =~ ~S(author: "Ada \"L\": Example")
    assert markdown =~ ~s(created_at: "2020-01-02T03:04:05.000Z")
    assert markdown =~ ~s(updated_at: "2026-09-20T12:34:56.789Z")
    assert markdown =~ "version: 7"
    assert markdown =~ "\n---\n\nBody\n"
    assert_received {:author_lookup, ["creator"]}
    refute_received {:author_lookup, _}
  end

  test "keeps the account ID when the profile is inaccessible, missing or unnamed", context do
    for response <- [
          {404, %{}},
          {200, %{"results" => []}},
          {200, %{"results" => [%{"accountId" => "creator", "displayName" => ""}]}}
        ] do
      stub(context.body, response)
      assert export(context) =~ ~s(author: "creator")
    end
  end

  test "missing metadata stays null without looking up a user", context do
    body = Map.drop(context.body, ["authorId", "createdAt", "version"])
    stub(body, nil)
    markdown = export(context)
    for key <- ["author", "created_at", "updated_at"], do: assert(markdown =~ "#{key}: null\n")
    refute_received {:author_lookup, _}
  end

  defp stub(body, user_response) do
    owner = self()

    Req.default_options(
      retry: false,
      adapter: fn request ->
        {status, response} =
          case {request.method, request.url.path} do
            {:get, "/wiki/api/v2/pages/1"} ->
              {200, body}

            {:get, "/wiki/api/v2/spaces/s/pages"} ->
              {200, %{"results" => [%{"id" => "1"}]}}

            {:post, "/wiki/api/v2/users-bulk"} ->
              send(owner, {:author_lookup, Jason.decode!(request.body)["accountIds"]})
              user_response

            _ ->
              raise "Unexpected request: #{request.method} #{request.url}"
          end

        {request, Req.Response.new(status: status, body: response)}
      end
    )
  end

  defp export(%{config: config, output: output}) do
    client = Client.new(config)

    {:ok, nodes} =
      if function_exported?(Client, :fetch_space_target_tree, 3) do
        target = %{id: "space:s", space: %{"id" => "s"}, space_key: "S", output_dir: "S"}

        apply(Client, :fetch_space_target_tree, [client, target, false])
      else
        apply(Client, :fetch_tree, [client, "1", false, false])
      end

    path = Path.join(output, "page.md")
    page = nodes |> Enum.find(&(&1.type == "page")) |> Map.put(:absolute_path, path)
    assert Writer.write_page(page, "Body", %{written: 0}) == %{written: 1}
    File.read!(path)
  end
end
