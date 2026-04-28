defmodule Anubis.Server.Component.URITemplateTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Component.URITemplate

  describe "parse/1" do
    test "parses template with single variable" do
      assert {:ok, %URITemplate{vars: ["path"], raw: "file:///{path}"}} =
               URITemplate.parse("file:///{path}")
    end

    test "parses template with multiple variables" do
      assert {:ok, %URITemplate{vars: ["table", "id"]}} =
               URITemplate.parse("db:///{table}/{id}")
    end

    test "parses template with no variables" do
      assert {:ok, %URITemplate{vars: []}} = URITemplate.parse("file:///static")
    end

    test "rejects unbalanced braces" do
      assert {:error, _} = URITemplate.parse("file:///{path")
      assert {:error, _} = URITemplate.parse("file:///path}")
    end

    test "rejects duplicate variables" do
      assert {:error, reason} = URITemplate.parse("/{x}/{x}")
      assert reason =~ "duplicate"
    end

    test "rejects non-string input" do
      assert {:error, _} = URITemplate.parse(:atom)
    end
  end

  describe "parse!/1" do
    test "raises on invalid template" do
      assert_raise ArgumentError, fn -> URITemplate.parse!("file:///{bad") end
    end
  end

  describe "match/2" do
    test "matches single variable" do
      {:ok, t} = URITemplate.parse("file:///{path}")
      assert {:ok, %{"path" => "readme.md"}} = URITemplate.match(t, "file:///readme.md")
    end

    test "matches multiple variables" do
      {:ok, t} = URITemplate.parse("db:///{table}/{id}")
      assert {:ok, %{"table" => "users", "id" => "42"}} = URITemplate.match(t, "db:///users/42")
    end

    test "returns :error on non-match" do
      {:ok, t} = URITemplate.parse("file:///{path}")
      assert :error = URITemplate.match(t, "http://example.com")
    end

    test "does not greedily span path separators" do
      {:ok, t} = URITemplate.parse("db:///{table}/{id}")
      assert :error = URITemplate.match(t, "db:///users")
    end

    test "percent-decodes captured values" do
      {:ok, t} = URITemplate.parse("file:///{path}")
      assert {:ok, %{"path" => "hello world"}} = URITemplate.match(t, "file:///hello%20world")
    end

    test "accepts a raw template string" do
      assert {:ok, %{"path" => "x"}} = URITemplate.match("file:///{path}", "file:///x")
    end
  end

  describe "Level 2 — reserved expansion {+var}" do
    test "matches path with slashes" do
      {:ok, t} = URITemplate.parse("file:///{+path}")

      assert {:ok, %{"path" => "deep/nested/file.md"}} =
               URITemplate.match(t, "file:///deep/nested/file.md")
    end

    test "still rejects fragment" do
      {:ok, t} = URITemplate.parse("file:///{+path}")
      assert :error = URITemplate.match(t, "file:///foo#frag")
    end
  end

  describe "Level 2 — fragment expansion {#var}" do
    test "matches fragment" do
      {:ok, t} = URITemplate.parse("/page{#section}")
      assert {:ok, %{"section" => "intro"}} = URITemplate.match(t, "/page#intro")
    end

    test "rejects when no fragment present" do
      {:ok, t} = URITemplate.parse("/page{#section}")
      assert :error = URITemplate.match(t, "/page")
    end
  end
end
