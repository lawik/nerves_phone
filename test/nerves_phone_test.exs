defmodule NervesPhoneTest do
  use ExUnit.Case
  doctest NervesPhone

  test "greets the world" do
    assert NervesPhone.hello() == :world
  end
end
