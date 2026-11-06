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

// The number of categorical series colors (`--series-1` ... in app.css).
const SERIES_COLORS = 8

// Response time chart of the monitor page.
//
// The element carries the series in `data-series` as JSON
// `[{id, name, points: [[unix_ms, response_ms | null, down (0|1)], ...]}]`
// and the window size in `data-range-ms`. One series is drawn as an area in
// the primary color; several (the members of a group, at most
// SERIES_COLORS) as lines in the categorical colors, in the given order,
// with a legend. New checks arrive
// as "response-chart:point" events (`{series: id, point}`) while
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

    this.handleEvent("response-chart:point", ({series: id, point}) => {
      if (this.el.dataset.live !== "true") return
      const series = this.series.find(s => s.id === id)
      if (!series) return
      series.points.push(point)
      const cutoff = Date.now() - Number(this.el.dataset.rangeMs)
      for (const s of this.series) {
        while (s.points.length && s.points[0][0] < cutoff) s.points.shift()
      }
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
    this.series = JSON.parse(this.el.dataset.series || "[]")
    this.render()
  },

  render() {
    if (!this.chart) return
    const text = cssColor("--color-base-content", 0.7)
    const grid = cssColor("--color-base-content", 0.1)
    const surface = cssColor("--color-base-100")
    const error = cssColor("--color-error")
    const now = Date.now()
    const rangeMs = Number(this.el.dataset.rangeMs)
    const multi = this.series.length > 1

    const lines = this.series.map((series, index) => {
      // The server sends at most SERIES_COLORS series.
      const color = cssColor(multi ? `--series-${(index % SERIES_COLORS) + 1}` : "--color-primary")
      const line = {
        name: series.name,
        type: "line",
        showSymbol: false,
        connectNulls: false,
        sampling: "lttb",
        lineStyle: {width: multi ? 2 : 1.5, color},
        itemStyle: {color},
        data: series.points.map(([t, ms]) => [t, ms]),
      }
      if (!multi) {
        line.areaStyle = {
          color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
            {offset: 0, color: cssColor("--color-primary", 0.35)},
            {offset: 1, color: cssColor("--color-primary", 0.02)},
          ]),
        }
      }
      return line
    })

    const down = {
      name: "Down",
      type: "scatter",
      symbolSize: 8,
      itemStyle: {color: error, borderColor: surface, borderWidth: 2},
      tooltip: {valueFormatter: () => "down"},
      data: this.series.flatMap(series =>
        series.points.filter(p => p[2] === 1).map(([t, ms]) => [t, ms ?? 0])
      ),
    }

    this.chart.setOption({
      backgroundColor: "transparent",
      animation: false,
      legend: multi
        ? {
            top: 0,
            left: 0,
            type: "scroll",
            icon: "roundRect",
            itemWidth: 12,
            itemHeight: 4,
            textStyle: {color: text},
            pageTextStyle: {color: text},
            data: this.series.map(s => s.name),
          }
        : {show: false},
      grid: {left: 8, right: 16, top: multi ? 40 : 16, bottom: 8, containLabel: true},
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
      series: [...lines, down],
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
