defmodule VoyagerWeb.HalloweenComponents do
  @moduledoc false
  use Phoenix.Component

  def halloween_decor(assigns) do
    ~H"""
    <div id="halloween-decor" class="halloween-decor" aria-hidden="true">
      <svg class="halloween-web stroke-base-content/25" viewBox="0 0 100 100" fill="none">
        <path d="M100 0L0 0M100 0L8 38M100 0L29 71M100 0L62 92M100 0L100 100" />
        <path d="M70 0Q74.1 5.1 72.4 11.4Q78 14.7 78.7 21.3Q85.3 22 88.6 27.6Q94.9 25.9 100 30" />
        <path d="M45 0Q52.5 9.4 49.4 20.9Q59.6 27 60.9 39.1Q73 40.4 79.1 50.6Q90.6 47.5 100 55" />
        <path d="M20 0Q30.9 13.7 26.4 30.4Q41.3 39.2 43.2 56.8Q60.8 58.7 69.6 73.6Q86.3 69.1 100 80" />
      </svg>

      <div class="halloween-spider">
        <svg viewBox="0 0 24 120" fill="none">
          <path class="stroke-base-content/40" d="M12 0V100" />
          <path
            class="halloween-legs stroke-base-content/70"
            stroke-width="1.2"
            stroke-linecap="round"
            d="M7 104Q2 99 1 94M7 106Q1 104 0 101M7 109Q1 111 0 115M7 111Q3 116 2 120M17 104Q22 99 23 94M17 106Q23 104 24 101M17 109Q23 111 24 115M17 111Q21 116 22 120"
          />
          <circle class="fill-secondary" cx="12" cy="100" r="3.5" />
          <ellipse class="fill-secondary" cx="12" cy="108" rx="6" ry="7" />
          <circle class="fill-accent" cx="10.6" cy="99.6" r="0.9" />
          <circle class="fill-accent" cx="13.4" cy="99.6" r="0.9" />
        </svg>
      </div>

      <div :for={n <- 1..2} class={"halloween-bat halloween-bat-#{n}"}>
        <svg class="fill-secondary/80" viewBox="0 0 64 32">
          <path d="M32 10C30 6 28 6 27 8C24 4 16 2 2 8C8 10 10 14 9 18C13 15 17 16 19 20C22 17 26 18 28 22C30 20 31 20 32 24C33 20 34 20 36 22C38 18 42 17 45 20C47 16 51 15 55 18C54 14 56 10 62 8C48 2 40 4 37 8C36 6 34 6 32 10Z" />
        </svg>
      </div>

      <div :for={n <- 1..2} class={"halloween-ghost halloween-ghost-#{n}"}>
        <svg viewBox="0 0 40 48">
          <path
            class="fill-base-content"
            d="M20 2C9 2 4 11 4 22V44L9 39L14 44L20 39L26 44L31 39L36 44V22C36 11 31 2 20 2Z"
          />
          <ellipse class="fill-base-300" cx="14" cy="20" rx="2.5" ry="3.5" />
          <ellipse class="fill-base-300" cx="26" cy="20" rx="2.5" ry="3.5" />
          <ellipse class="fill-base-300" cx="20" cy="30" rx="3" ry="4" />
        </svg>
      </div>

      <div class="halloween-pumpkins">
        <svg
          :for={size <- ["lg", "sm"]}
          class={"halloween-pumpkin halloween-pumpkin-#{size}"}
          viewBox="0 0 48 44"
        >
          <path class="fill-success" d="M22 2Q24 0 27 2L26 9H22Z" />
          <g class="fill-primary stroke-primary-content/30">
            <ellipse cx="16" cy="26" rx="12" ry="16" />
            <ellipse cx="32" cy="26" rx="12" ry="16" />
            <ellipse cx="24" cy="26" rx="11" ry="17" />
          </g>
          <path
            class="halloween-face fill-warning"
            d="M14 20L19 14L22 21ZM26 21L29 14L34 20ZM22 25L24 22L26 25ZM12 29Q24 42 36 29L32 31L30 28L27 32L24 29L21 32L18 28L16 31Z"
          />
        </svg>
      </div>
    </div>
    """
  end
end
