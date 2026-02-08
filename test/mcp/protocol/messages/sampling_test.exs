defmodule MCP.Protocol.Messages.SamplingTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Messages.Sampling

  describe "CreateMessageParams" do
    test "from_map/1 parses sampling request" do
      map = %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}
        ],
        "maxTokens" => 1000,
        "systemPrompt" => "Be helpful",
        "temperature" => 0.7,
        "modelPreferences" => %{
          "hints" => [%{"name" => "claude-3"}],
          "intelligencePriority" => 0.9
        }
      }

      params = Sampling.CreateMessageParams.from_map(map)

      assert length(params.messages) == 1
      assert hd(params.messages).role == "user"
      assert params.max_tokens == 1000
      assert params.system_prompt == "Be helpful"
      assert params.temperature == 0.7
      assert params.model_preferences.intelligence_priority == 0.9
      assert hd(params.model_preferences.hints).name == "claude-3"
    end

    test "round-trips through JSON with camelCase" do
      map = %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "Hi"}}
        ],
        "maxTokens" => 500,
        "systemPrompt" => "test"
      }

      params = Sampling.CreateMessageParams.from_map(map)
      json = Jason.encode!(params)
      decoded = Jason.decode!(json)

      assert decoded["maxTokens"] == 500
      assert decoded["systemPrompt"] == "test"
      refute Map.has_key?(decoded, "max_tokens")
      refute Map.has_key?(decoded, "system_prompt")
    end
  end

  describe "CreateMessageResult" do
    test "from_map/1 parses sampling result" do
      map = %{
        "role" => "assistant",
        "content" => %{"type" => "text", "text" => "Hello!"},
        "model" => "claude-3-sonnet",
        "stopReason" => "endTurn"
      }

      result = Sampling.CreateMessageResult.from_map(map)

      assert result.role == "assistant"
      assert result.content.text == "Hello!"
      assert result.model == "claude-3-sonnet"
      assert result.stop_reason == "endTurn"
    end

    test "round-trips through JSON" do
      map = %{
        "role" => "assistant",
        "content" => %{"type" => "text", "text" => "Hi"},
        "model" => "test-model"
      }

      result = Sampling.CreateMessageResult.from_map(map)
      json = Jason.encode!(result)
      decoded = Jason.decode!(json)

      assert decoded["role"] == "assistant"
      assert decoded["model"] == "test-model"
      refute Map.has_key?(decoded, "stopReason")
    end
  end
end
