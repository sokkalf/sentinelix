import * as echarts from "../vendor/echarts/echarts.min.js"

const Hooks = {}

// Resolves a CSS color (e.g. a daisyUI `oklch(...)` variable) to an
// `rgba()` string ECharts can work with, by painting it on a 1x1 canvas.
const colorCanvas = document.createElement("canvas")
colorCanvas.width = colorCanvas.height = 1
const colorCtx = colorCanvas.getContext("2d", {willReadFrequently: true})

const cssColor = (name, alpha = 1) => {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  if (!value) return undefined
  colorCtx.clearRect(0, 0, 1, 1)
  colorCtx.fillStyle = "#000"
  colorCtx.fillStyle = value
  colorCtx.fillRect(0, 0, 1, 1)
  const [r, g, b] = colorCtx.getImageData(0, 0, 1, 1).data
  return `rgba(${r}, ${g}, ${b}, ${alpha})`
}

const formatMs = value => value == null ? "–" : `${Math.round(value)} ms`

// Response time chart of the monitor page.
//
// The element carries the full series in `data-points` as JSON
// `[[unix_ms, response_ms | null, down (0|1)], ...]` and the window size in
// `data-range-ms`. New checks arrive as "response-chart:point" events while
// `data-live` is "true" (raw, not bucketed ranges).
Hooks.ResponseChart = {
  mounted() {
    this.container = this.el.querySelector(`#${this.el.id}-canvas`)
    this.chart = echarts.init(this.container, null, {renderer: "canvas"})
    this.load()

    this.resizeObserver = new ResizeObserver(() => this.chart.resize())
    this.resizeObserver.observe(this.container)
    this.onWindowResize = () => this.chart.resize()
    window.addEventListener("resize", this.onWindowResize)

    // Re-color when the light/dark theme changes.
    this.themeObserver = new MutationObserver(() => this.render())
    this.themeObserver.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})

    this.handleEvent("response-chart:point", ({point}) => {
      if (this.el.dataset.live !== "true") return
      this.points.push(point)
      const cutoff = Date.now() - Number(this.el.dataset.rangeMs)
      while (this.points.length && this.points[0][0] < cutoff) this.points.shift()
      this.render()
    })
  },

  updated() {
    this.load()
  },

  destroyed() {
    this.resizeObserver?.disconnect()
    this.themeObserver?.disconnect()
    window.removeEventListener("resize", this.onWindowResize)
    this.chart?.dispose()
    this.chart = null
  },

  load() {
    this.points = JSON.parse(this.el.dataset.points || "[]")
    this.render()
  },

  render() {
    if (!this.chart) return
    const text = cssColor("--color-base-content", 0.7)
    const grid = cssColor("--color-base-content", 0.1)
    const primary = cssColor("--color-primary")
    const error = cssColor("--color-error")
    const now = Date.now()
    const rangeMs = Number(this.el.dataset.rangeMs)

    this.chart.setOption({
      backgroundColor: "transparent",
      animation: false,
      grid: {left: 8, right: 16, top: 16, bottom: 8, containLabel: true},
      tooltip: {
        trigger: "axis",
        valueFormatter: formatMs,
        backgroundColor: cssColor("--color-base-100"),
        borderColor: grid,
        textStyle: {color: cssColor("--color-base-content")},
      },
      xAxis: {
        type: "time",
        min: now - rangeMs,
        max: now,
        axisLine: {lineStyle: {color: grid}},
        axisLabel: {color: text, hideOverlap: true},
        splitLine: {show: false},
      },
      yAxis: {
        type: "value",
        min: 0,
        axisLabel: {color: text, formatter: "{value} ms"},
        splitLine: {lineStyle: {color: grid}},
      },
      series: [
        {
          name: "Response time",
          type: "line",
          showSymbol: false,
          connectNulls: false,
          sampling: "lttb",
          lineStyle: {width: 1.5, color: primary},
          itemStyle: {color: primary},
          areaStyle: {
            color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
              {offset: 0, color: cssColor("--color-primary", 0.35)},
              {offset: 1, color: cssColor("--color-primary", 0.02)},
            ]),
          },
          data: this.points.map(([t, ms]) => [t, ms]),
        },
        {
          name: "Down",
          type: "scatter",
          symbolSize: 6,
          itemStyle: {color: error},
          tooltip: {valueFormatter: () => "down"},
          data: this.points.filter(p => p[2] === 1).map(([t, ms]) => [t, ms ?? 0]),
        },
      ],
    }, {notMerge: true})
  },
}

// Shows a `<time datetime="...">` in the browser's local time zone.
Hooks.LocalTime = {
  mounted() { this.format() },
  updated() { this.format() },
  format() {
    const date = new Date(this.el.getAttribute("datetime"))
    if (isNaN(date)) return
    this.el.textContent = date.toLocaleString(undefined, {dateStyle: "medium", timeStyle: "medium"})
  },
}

// Copies the value of the input referenced by `data-target`.
Hooks.CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      const input = document.getElementById(this.el.dataset.target)
      if (!input) return
      navigator.clipboard?.writeText(input.value).then(() => {
        const original = this.el.innerHTML
        this.el.textContent = "Copied!"
        setTimeout(() => { this.el.innerHTML = original }, 1500)
      })
    })
  },
}

export default Hooks
