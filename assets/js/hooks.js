import * as echarts from "../vendor/echarts/echarts.min.js"

const Hooks = {}

Hooks.Chart = {
  mounted() {
    const selector = "#" + this.el.id
    this.chart = echarts.init(this.el.querySelector(selector + "-chart"), "dark")
    const option = JSON.parse(this.el.querySelector(selector + "-data").textContent)
    this.chart.setOption(option)
  },
  updated() {
    const selector = "#" + this.el.id
    const option = JSON.parse(this.el.querySelector(selector + "-data").textContent)
    this.chart.setOption(option)
  },
}

export default Hooks
