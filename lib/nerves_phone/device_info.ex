defmodule NervesPhone.DeviceInfo do
  @moduledoc """
  Facts about the phone for Settings, in titled sections of label/value
  pairs. Anything that can't be read (on the host, say) is left out.
  """

  alias Nerves.Runtime.KV

  @doc "Every section, read now."
  def read do
    [
      {"Phone",
       [
         {"Model", model()},
         {"Hostname", hostname()},
         {"Serial number", safe(&Nerves.Runtime.serial_number/0)}
       ]},
      {"Firmware",
       [
         {"Product", KV.get_active("nerves_fw_product")},
         {"Version", KV.get_active("nerves_fw_version")},
         {"UUID", KV.get_active("nerves_fw_uuid")},
         {"Active slot", KV.get("nerves_fw_active")},
         {"Validated",
          safe(fn -> if Nerves.Runtime.firmware_valid?(), do: "Yes", else: "No" end)},
         {"Platform", KV.get_active("nerves_fw_platform")},
         {"Architecture", KV.get_active("nerves_fw_architecture")}
       ]},
      {"System",
       [
         {"Kernel", kernel()},
         {"Uptime", uptime()},
         {"Erlang/OTP", to_string(:erlang.system_info(:otp_release))},
         {"Elixir", System.version()}
       ]},
      {"Memory and storage",
       [
         {"Memory", memory()},
         {"Storage", storage()}
       ]}
    ]
    |> Enum.map(fn {title, rows} ->
      {title, Enum.reject(rows, fn {_label, value} -> value in [nil, ""] end)}
    end)
    |> Enum.reject(fn {_title, rows} -> rows == [] end)
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  end

  def hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  defp model do
    case File.read("/proc/device-tree/model") do
      {:ok, model} -> model |> String.trim_trailing(<<0>>) |> String.trim()
      _ -> nil
    end
  end

  defp kernel do
    case File.read("/proc/sys/kernel/osrelease") do
      {:ok, release} -> String.trim(release)
      _ -> nil
    end
  end

  defp uptime do
    seconds =
      with {:ok, text} <- File.read("/proc/uptime"),
           {seconds, _} <- Float.parse(text) do
        trunc(seconds)
      else
        _ -> div(elem(:erlang.statistics(:wall_clock), 0), 1000)
      end

    days = div(seconds, 86_400)
    hours = seconds |> rem(86_400) |> div(3600)
    minutes = seconds |> rem(3600) |> div(60)

    cond do
      days > 0 -> "#{days} d #{hours} h"
      hours > 0 -> "#{hours} h #{minutes} min"
      true -> "#{minutes} min"
    end
  end

  defp memory do
    with {:ok, text} <- File.read("/proc/meminfo"),
         %{"MemTotal" => total, "MemAvailable" => available} <- meminfo(text) do
      "#{size(available * 1024)} free of #{size(total * 1024)}"
    else
      _ -> nil
    end
  end

  defp meminfo(text) do
    for line <- String.split(text, "\n"),
        [key, rest] <- [String.split(line, ":", parts: 2)],
        {kb, _} <- [Integer.parse(String.trim(rest))],
        into: %{},
        do: {key, kb}
  end

  # The filesystem the phone's own files are on (/data on the phone).
  defp storage do
    dir = NervesPhone.state_dir()
    File.mkdir_p(dir)

    with {output, 0} <- System.cmd("df", ["-k", dir], stderr_to_stdout: true),
         [_header, line | _] <- String.split(output, "\n", trim: true),
         [_fs, total, _used, available | _] <- String.split(line),
         {total, _} <- Integer.parse(total),
         {available, _} <- Integer.parse(available) do
      "#{size(available * 1024)} free of #{size(total * 1024)}"
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "A byte count for people: 1.2 GB, 340 MB."
  def size(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 1)} GB"
      bytes >= 1_000_000 -> "#{round(bytes / 1_000_000)} MB"
      true -> "#{round(bytes / 1_000)} kB"
    end
  end
end
