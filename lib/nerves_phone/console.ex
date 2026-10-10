defmodule NervesPhone.Console do
  @moduledoc """
  Takes the kernel's framebuffer console off the panel once the UI is up.

  The system boots with `console=tty0`, so the kernel draws its messages
  on the display through fbcon (rotated, in a 16x32 font). That's useful
  while booting, but once Emerge owns the panel every kernel message is
  still rendered into the framebuffer console behind it, and a burst of
  them stalls the BEAM: after a resume from suspend the camera drivers
  print two warning backtraces, and with fbcon bound that froze the UI
  for about eleven seconds, against one with it unbound.

  Unbinding fbcon (`/sys/class/vtconsole/vtconN/bind`) only stops the
  drawing. The messages still go to the log buffer, so `dmesg` and
  RingLogger (nerves_logging's kmsg tailer) keep them, and to the serial
  console. The on-screen IEx prompt erlinit opens on tty1 stops being
  rendered too, which is fine with the UI covering the panel.

  On the host there's no vtconsole directory, so this does nothing.
  """

  require Logger

  @vtconsoles "/sys/class/vtconsole"

  @doc """
  Unbinds every framebuffer console found under `root`. Returns the
  consoles it unbound.
  """
  @spec release_panel(Path.t()) :: [Path.t()]
  def release_panel(root \\ @vtconsoles) do
    root
    |> Path.join("vtcon*")
    |> Path.wildcard()
    |> Enum.filter(&framebuffer_console?/1)
    |> Enum.filter(&unbind/1)
  end

  defp framebuffer_console?(vtcon) do
    case File.read(Path.join(vtcon, "name")) do
      {:ok, name} -> String.contains?(name, "frame buffer")
      _ -> false
    end
  end

  defp unbind(vtcon) do
    bind = Path.join(vtcon, "bind")

    case File.read(bind) do
      {:ok, "1\n"} ->
        case File.write(bind, "0") do
          :ok ->
            Logger.info("Unbound the framebuffer console #{vtcon} from the panel")
            true

          {:error, reason} ->
            Logger.warning("Couldn't unbind the framebuffer console #{vtcon}: #{inspect(reason)}")
            false
        end

      _ ->
        false
    end
  end
end
