defmodule SentinelixWeb.OIDCHTML do
  use SentinelixWeb, :html

  def denied(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="access-denied" class="mx-auto max-w-md space-y-6 py-8 text-center">
        <.icon name="hero-no-symbol" class="size-12 text-error" />
        <.header>
          Access denied
          <:subtitle>
            You signed in successfully, but your account is not allowed to use Sentinelix.
            Ask an administrator to add you to an allowed group, email address or domain.
          </:subtitle>
        </.header>
        <.button href={~p"/login"}>Back to sign in</.button>
      </div>
    </Layouts.app>
    """
  end
end
