defmodule NervesPhone.MicTest do
  # The top mic is off by default and switched on as a second channel with
  # amixer, with the ALSA "mic" device following the channel count.
  use ExUnit.Case

  alias NervesPhone.Audio.Mic

  @fake_dir Path.expand("../../tmp/test/fake_bin", __DIR__)
  @log Path.join(@fake_dir, "amixer.log")

  setup do
    File.mkdir_p!(@fake_dir)
    fake = Path.join(@fake_dir, "amixer")

    File.write!(
      fake,
      "#!/bin/sh\necho \"$@\" >> #{@log}\n[ -e #{@fake_dir}/fail ] && exit 1\nexit 0\n"
    )

    File.chmod!(fake, 0o755)
    File.rm(@log)
    File.rm(Path.join(@fake_dir, "fail"))

    path = System.get_env("PATH")
    System.put_env("PATH", @fake_dir <> ":" <> path)
    Application.put_env(:nerves_phone, :mic_control, :alsa)

    on_exit(fn ->
      System.put_env("PATH", path)
      Application.delete_env(:nerves_phone, :mic_control)
      restart()
    end)

    restart()
    :ok
  end

  test "starts with the top mic off and a mono mic device" do
    refute Mic.secondary?()
    assert Mic.channels() == 1
    assert File.read!(Mic.conf_path()) =~ "channels 1"
    # Startup forces the second port off.
    assert log() =~ "name=AIF1_CAP Mixer SLIM TX8 off"
  end

  test "the top mic can't be switched on until the kernel supports it" do
    assert {:error, :unsupported} = Mic.set_secondary(true)
    refute Mic.secondary?()
    assert File.read!(Mic.conf_path()) =~ "channels 1"
  end

  test "switching the top mic on routes DMIC2 to TX8 and makes the device stereo" do
    experimental()
    assert :ok = Mic.set_secondary(true)
    assert Mic.secondary?()
    assert Mic.channels() == 2
    assert File.read!(Mic.conf_path()) =~ "channels 2"

    assert log() =~ "name=DMIC MUX8 DMIC2"
    assert log() =~ "name=AIF1_CAP Mixer SLIM TX8 on"

    assert :ok = Mic.set_secondary(false)
    assert Mic.channels() == 1
    assert File.read!(Mic.conf_path()) =~ "channels 1"
  end

  test "a refused mixer change leaves everything as it was" do
    experimental()
    File.touch!(Path.join(@fake_dir, "fail"))
    assert {:error, _} = Mic.set_secondary(true)
    refute Mic.secondary?()
    assert File.read!(Mic.conf_path()) =~ "channels 1"
  end

  defp experimental do
    Application.put_env(:nerves_phone, :mic_secondary, :experimental)
    on_exit(fn -> Application.delete_env(:nerves_phone, :mic_secondary) end)
  end

  defp restart do
    :ok = Supervisor.terminate_child(NervesPhone.Supervisor, Mic)
    {:ok, _} = Supervisor.restart_child(NervesPhone.Supervisor, Mic)
  end

  defp log, do: File.read!(@log)
end
