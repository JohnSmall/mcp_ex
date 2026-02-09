defmodule MCP.Conformance.ServerHandler do
  @moduledoc """
  Handler module implementing all MCP conformance test tools, resources, and prompts.
  """

  @behaviour MCP.Server.Handler

  @test_image_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
  @test_audio_base64 "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAAB9AAACABAAZGF0YQIAAAA="

  @impl true
  def init(_opts) do
    {:ok,
     %{
       subscriptions: [],
       log_level: nil
     }}
  end

  # --- Tools ---

  @impl true
  def handle_list_tools(_cursor, state) do
    tools = [
      %{
        "name" => "test_simple_text",
        "description" => "Tests simple text content response",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_image_content",
        "description" => "Tests image content response",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_audio_content",
        "description" => "Tests audio content response",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_multiple_content_types",
        "description" => "Tests multiple content types in response",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_embedded_resource",
        "description" => "Tests embedded resource content",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_tool_with_logging",
        "description" => "Tests tool with logging notifications",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_tool_with_progress",
        "description" => "Tests tool with progress notifications",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_error_handling",
        "description" => "Tests error handling",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_sampling",
        "description" => "Tests sampling via server-initiated request",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"prompt" => %{"type" => "string"}},
          "required" => ["prompt"]
        }
      },
      %{
        "name" => "test_elicitation",
        "description" => "Tests elicitation via server-initiated request",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"message" => %{"type" => "string"}},
          "required" => ["message"]
        }
      },
      %{
        "name" => "test_elicitation_sep1034_defaults",
        "description" => "Tests elicitation with default values",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_elicitation_sep1330_enums",
        "description" => "Tests elicitation with enum schemas",
        "inputSchema" => %{"type" => "object"}
      }
    ]

    {:ok, tools, nil, state}
  end

  @impl true
  def handle_call_tool("test_simple_text", _args, state) do
    {:ok, [%{"type" => "text", "text" => "This is a simple text response for testing."}], state}
  end

  def handle_call_tool("test_image_content", _args, state) do
    {:ok,
     [%{"type" => "image", "data" => @test_image_base64, "mimeType" => "image/png"}], state}
  end

  def handle_call_tool("test_audio_content", _args, state) do
    {:ok,
     [%{"type" => "audio", "data" => @test_audio_base64, "mimeType" => "audio/wav"}], state}
  end

  def handle_call_tool("test_multiple_content_types", _args, state) do
    content = [
      %{"type" => "text", "text" => "Multiple content types test:"},
      %{"type" => "image", "data" => @test_image_base64, "mimeType" => "image/png"},
      %{
        "type" => "resource",
        "resource" => %{
          "uri" => "test://mixed-content-resource",
          "mimeType" => "application/json",
          "text" => Jason.encode!(%{"test" => "data", "value" => 123})
        }
      }
    ]

    {:ok, content, state}
  end

  def handle_call_tool("test_embedded_resource", _args, state) do
    content = [
      %{
        "type" => "resource",
        "resource" => %{
          "uri" => "test://embedded-resource",
          "mimeType" => "text/plain",
          "text" => "This is an embedded resource content."
        }
      }
    ]

    {:ok, content, state}
  end

  def handle_call_tool("test_tool_with_logging", _args, state) do
    # Note: logging notifications require SSE streaming within the POST response.
    # For now, return the result directly (logging scenarios may fail).
    {:ok,
     [%{"type" => "text", "text" => "Tool with logging executed successfully"}], state}
  end

  def handle_call_tool("test_tool_with_progress", _args, state) do
    # Note: progress notifications require SSE streaming within the POST response.
    # For now, return the result directly (progress scenarios may fail).
    {:ok, [%{"type" => "text", "text" => "progress-token"}], state}
  end

  def handle_call_tool("test_error_handling", _args, state) do
    {:ok,
     [%{"type" => "text", "text" => "This tool intentionally returns an error for testing"}],
     true, state}
  end

  def handle_call_tool("test_sampling", _args, state) do
    # Sampling requires server→client request during tool execution.
    # This cannot work synchronously in our current architecture.
    {:ok,
     [%{"type" => "text", "text" => "LLM response: sampling not available in sync mode"}],
     state}
  end

  def handle_call_tool("test_elicitation", _args, state) do
    # Elicitation requires server→client request during tool execution.
    {:ok,
     [%{"type" => "text", "text" => "User response: elicitation not available in sync mode"}],
     state}
  end

  def handle_call_tool("test_elicitation_sep1034_defaults", _args, state) do
    {:ok,
     [%{"type" => "text", "text" => "Elicitation defaults not available in sync mode"}], state}
  end

  def handle_call_tool("test_elicitation_sep1330_enums", _args, state) do
    {:ok,
     [%{"type" => "text", "text" => "Elicitation enums not available in sync mode"}], state}
  end

  def handle_call_tool(name, _args, state) do
    {:error, -32_601, "Unknown tool: #{name}", state}
  end

  # --- Resources ---

  @impl true
  def handle_list_resources(_cursor, state) do
    resources = [
      %{
        "uri" => "test://static-text",
        "name" => "Static Text Resource",
        "mimeType" => "text/plain"
      },
      %{
        "uri" => "test://static-binary",
        "name" => "Static Binary Resource",
        "mimeType" => "image/png"
      },
      %{
        "uri" => "test://watched-resource",
        "name" => "Watched Resource",
        "mimeType" => "text/plain"
      }
    ]

    {:ok, resources, nil, state}
  end

  @impl true
  def handle_read_resource("test://static-text", state) do
    {:ok,
     [
       %{
         "uri" => "test://static-text",
         "mimeType" => "text/plain",
         "text" => "This is the content of the static text resource."
       }
     ], state}
  end

  def handle_read_resource("test://static-binary", state) do
    {:ok,
     [
       %{
         "uri" => "test://static-binary",
         "mimeType" => "image/png",
         "blob" => @test_image_base64
       }
     ], state}
  end

  def handle_read_resource("test://watched-resource", state) do
    {:ok,
     [
       %{
         "uri" => "test://watched-resource",
         "mimeType" => "text/plain",
         "text" => "Watched resource content"
       }
     ], state}
  end

  def handle_read_resource("test://template/" <> rest, state) do
    # Parse template URI: test://template/{id}/data
    id = rest |> String.split("/") |> hd()

    {:ok,
     [
       %{
         "uri" => "test://template/#{id}/data",
         "mimeType" => "application/json",
         "text" =>
           Jason.encode!(%{"id" => id, "templateTest" => true, "data" => "Data for ID: #{id}"})
       }
     ], state}
  end

  def handle_read_resource(uri, state) do
    {:error, -32_002, "Resource not found: #{uri}", state}
  end

  @impl true
  def handle_subscribe(uri, state) do
    {:ok, %{state | subscriptions: [uri | state.subscriptions]}}
  end

  @impl true
  def handle_unsubscribe(uri, state) do
    {:ok, %{state | subscriptions: List.delete(state.subscriptions, uri)}}
  end

  @impl true
  def handle_list_resource_templates(_cursor, state) do
    templates = [
      %{
        "uriTemplate" => "test://template/{id}/data",
        "name" => "Template Resource",
        "description" => "A resource template with ID parameter",
        "mimeType" => "application/json"
      }
    ]

    {:ok, templates, nil, state}
  end

  # --- Prompts ---

  @impl true
  def handle_list_prompts(_cursor, state) do
    prompts = [
      %{
        "name" => "test_simple_prompt",
        "description" => "Simple prompt without arguments"
      },
      %{
        "name" => "test_prompt_with_arguments",
        "description" => "Prompt with arguments",
        "arguments" => [
          %{
            "name" => "arg1",
            "description" => "First test argument",
            "required" => true
          },
          %{
            "name" => "arg2",
            "description" => "Second test argument",
            "required" => true
          }
        ]
      },
      %{
        "name" => "test_prompt_with_embedded_resource",
        "description" => "Prompt with embedded resource",
        "arguments" => [
          %{
            "name" => "resourceUri",
            "description" => "URI of the resource to embed",
            "required" => true
          }
        ]
      },
      %{
        "name" => "test_prompt_with_image",
        "description" => "Prompt with image content"
      }
    ]

    {:ok, prompts, nil, state}
  end

  @impl true
  def handle_get_prompt("test_simple_prompt", _args, state) do
    {:ok,
     %{
       "messages" => [
         %{
           "role" => "user",
           "content" => %{
             "type" => "text",
             "text" => "This is a simple prompt for testing."
           }
         }
       ]
     }, state}
  end

  def handle_get_prompt("test_prompt_with_arguments", args, state) do
    arg1 = Map.get(args || %{}, "arg1", "")
    arg2 = Map.get(args || %{}, "arg2", "")

    {:ok,
     %{
       "messages" => [
         %{
           "role" => "user",
           "content" => %{
             "type" => "text",
             "text" => "Prompt with arguments: arg1='#{arg1}', arg2='#{arg2}'"
           }
         }
       ]
     }, state}
  end

  def handle_get_prompt("test_prompt_with_embedded_resource", args, state) do
    uri = Map.get(args || %{}, "resourceUri", "test://example-resource")

    {:ok,
     %{
       "messages" => [
         %{
           "role" => "user",
           "content" => %{
             "type" => "resource",
             "resource" => %{
               "uri" => uri,
               "mimeType" => "text/plain",
               "text" => "Embedded resource content for testing."
             }
           }
         },
         %{
           "role" => "user",
           "content" => %{
             "type" => "text",
             "text" => "Please process the embedded resource above."
           }
         }
       ]
     }, state}
  end

  def handle_get_prompt("test_prompt_with_image", _args, state) do
    {:ok,
     %{
       "messages" => [
         %{
           "role" => "user",
           "content" => %{
             "type" => "image",
             "data" => @test_image_base64,
             "mimeType" => "image/png"
           }
         },
         %{
           "role" => "user",
           "content" => %{
             "type" => "text",
             "text" => "Please analyze the image above."
           }
         }
       ]
     }, state}
  end

  def handle_get_prompt(name, _args, state) do
    {:error, -32_601, "Unknown prompt: #{name}", state}
  end

  # --- Logging ---

  @impl true
  def handle_set_log_level(level, state) do
    {:ok, %{state | log_level: level}}
  end

  # --- Completion ---

  @impl true
  def handle_complete(_ref, _argument, state) do
    {:ok, %{"values" => [], "total" => 0, "hasMore" => false}, state}
  end
end
