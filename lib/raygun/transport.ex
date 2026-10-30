defmodule Raygun.Transport do
  @moduledoc "Interface de transport synchrone, remplaçable dans les tests."
  @callback post(binary(), binary(), map(), keyword()) ::
              {:ok, HTTPoison.Response.t()} | {:error, term()}
end

defmodule Raygun.Transport.HTTPoison do
  @moduledoc false
  @behaviour Raygun.Transport

  @impl true
  def post(url, body, headers, options), do: HTTPoison.post(url, body, headers, options)
end
