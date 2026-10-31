// Expanded/collapsed dashboard groups, remembered for the session.
//
// The dashboard pushes its overrides (group id => {open, problems}) as the
// "dashboard:groups" event whenever one changes; they are kept in
// sessionStorage and sent back as the `dashboard_groups` connect parameter,
// so they apply on reloads and reconnects. See SentinelixWeb.DashboardLive.
const KEY = "sentinelix:dashboard-groups"

export const readDashboardGroups = () => {
  try {
    const groups = JSON.parse(window.sessionStorage.getItem(KEY) || "{}")
    return groups && typeof groups === "object" && !Array.isArray(groups) ? groups : {}
  } catch (_error) {
    return {}
  }
}

export const storeDashboardGroups = () => {
  window.addEventListener("phx:dashboard:groups", ({detail}) => {
    try {
      window.sessionStorage.setItem(KEY, JSON.stringify(detail.groups || {}))
    } catch (_error) {
      // Storage full or disabled: the state lasts until the next reload.
    }
  })
}
