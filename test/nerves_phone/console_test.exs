defmodule NervesPhone.ConsoleTest do
  use ExUnit.Case, async: true

  alias NervesPhone.Console

  setup do
    root = Path.join(System.tmp_dir!(), "vtconsole-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    vtcon(root, "vtcon0", "(S) dummy device", "0")
    vtcon(root, "vtcon1", "(M) frame buffer device", "1")
    {:ok, root: root}
  end

  defp vtcon(root, name, desc, bound) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "name"), desc <> "\n")
    File.write!(Path.join(dir, "bind"), bound <> "\n")
    dir
  end

  test "unbinds only the framebuffer console", %{root: root} do
    assert Console.release_panel(root) == [Path.join(root, "vtcon1")]
    assert File.read!(Path.join(root, "vtcon1/bind")) == "0"
    assert File.read!(Path.join(root, "vtcon0/bind")) == "0\n"
  end

  test "leaves an already unbound console alone", %{root: root} do
    File.write!(Path.join(root, "vtcon1/bind"), "0\n")
    assert Console.release_panel(root) == []
  end

  test "does nothing without a vtconsole directory" do
    assert Console.release_panel("/nonexistent/vtconsole") == []
  end
end
