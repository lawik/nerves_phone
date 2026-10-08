# Tests keep their files in tmp/test (config/host.exs); start from none.
File.rm_rf!(NervesPhone.state_dir())
ExUnit.start()
