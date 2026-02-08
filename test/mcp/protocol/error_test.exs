defmodule MCP.Protocol.ErrorTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Error

  describe "error codes" do
    test "standard JSON-RPC error codes" do
      assert Error.parse_error_code() == -32_700
      assert Error.invalid_request_code() == -32_600
      assert Error.method_not_found_code() == -32_601
      assert Error.invalid_params_code() == -32_602
      assert Error.internal_error_code() == -32_603
    end

    test "MCP-specific error codes" do
      assert Error.resource_not_found_code() == -32_002
      assert Error.url_elicitation_required_code() == -32_042
    end
  end

  describe "constructor helpers" do
    test "parse_error/0" do
      error = Error.parse_error()
      assert error.code == -32_700
      assert error.message == "Parse error"
      assert error.data == nil
    end

    test "parse_error/1 with data" do
      error = Error.parse_error("unexpected token")
      assert error.code == -32_700
      assert error.data == "unexpected token"
    end

    test "invalid_request/0" do
      error = Error.invalid_request()
      assert error.code == -32_600
      assert error.message == "Invalid request"
    end

    test "method_not_found/1" do
      error = Error.method_not_found("unknown/method")
      assert error.code == -32_601
      assert error.data == "unknown/method"
    end

    test "invalid_params/1" do
      error = Error.invalid_params("missing required field")
      assert error.code == -32_602
      assert error.data == "missing required field"
    end

    test "internal_error/0" do
      error = Error.internal_error()
      assert error.code == -32_603
      assert error.message == "Internal error"
    end

    test "resource_not_found/1" do
      error = Error.resource_not_found("file:///missing")
      assert error.code == -32_002
      assert error.data == "file:///missing"
    end

    test "url_elicitation_required/1" do
      data = %{"url" => "https://auth.example.com", "description" => "Login required"}
      error = Error.url_elicitation_required(data)
      assert error.code == -32_042
      assert error.data == data
    end
  end

  describe "JSON encoding" do
    test "encodes to JSON with all fields" do
      error = Error.parse_error("bad json")
      json = Jason.encode!(error)
      decoded = Jason.decode!(json)

      assert decoded["code"] == -32_700
      assert decoded["message"] == "Parse error"
      assert decoded["data"] == "bad json"
    end

    test "encodes nil data as null" do
      error = Error.parse_error()
      json = Jason.encode!(error)
      decoded = Jason.decode!(json)

      assert decoded["code"] == -32_700
      assert decoded["data"] == nil
    end
  end

  describe "from_map/1" do
    test "parses error from wire format" do
      map = %{"code" => -32_601, "message" => "Method not found", "data" => "foo/bar"}
      error = Error.from_map(map)

      assert error.code == -32_601
      assert error.message == "Method not found"
      assert error.data == "foo/bar"
    end

    test "parses error without data" do
      map = %{"code" => -32_603, "message" => "Internal error"}
      error = Error.from_map(map)

      assert error.code == -32_603
      assert error.data == nil
    end
  end
end
