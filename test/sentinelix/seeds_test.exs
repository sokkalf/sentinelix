defmodule Sentinelix.SeedsTest do
  use Sentinelix.DataCase, async: true

  import ExUnit.CaptureIO

  alias Sentinelix.Monitoring

  @seeds Path.expand("../../priv/repo/seeds.exs", __DIR__)

  test "seeds create example monitors once" do
    capture_io(fn -> Code.eval_file(@seeds) end)
    monitors = Monitoring.list_monitors()
    assert length(monitors) >= 2

    # Running them again doesn't duplicate anything.
    capture_io(fn -> Code.eval_file(@seeds) end)
    assert length(Monitoring.list_monitors()) == length(monitors)
  end
end
