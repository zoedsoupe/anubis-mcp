defmodule HermesTest do
  use ExUnit.Case
  doctest Hermes

  test "greets the world" do
    assert Hermes.hello() == :world
  end
end
