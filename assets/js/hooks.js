import * as echarts from "../vendor/echarts/echarts.min.js"
let Hooks = {};

Hooks.Chart = {
	mounted() {
		selector = "#" + this.el.id
		this.chart = echarts.init(this.el.querySelector(selector + "-chart"), 'dark')
		option = JSON.parse(this.el.querySelector(selector + "-data").textContent)
		this.chart.setOption(option)
	},
	updated() {
		selector = "#" + this.el.id
		option = JSON.parse(this.el.querySelector(selector + "-data").textContent)
		this.chart.setOption(option)
	}
}

export default Hooks;
