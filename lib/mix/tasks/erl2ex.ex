# Mix task for erl2ex

defmodule Mix.Tasks.Erl2exVendored do

  @moduledoc Erl2exVendored.Cli.usage_text("mix erl2ex")

  @shortdoc "Transpiles Erlang source to Elixir"

  use Mix.Task

  @impl true
  @spec run(OptionParser.argv) :: no_return
  def run(args) do
    Erl2exVendored.Cli.main(args)
  end

end
