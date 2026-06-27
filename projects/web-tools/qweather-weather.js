/**
 * 和风天气 v1.0
 * @author: mo (based on Peng-YM's 彩云天气)
 *
 * 和风天气 API: https://dev.qweather.com/
 * 注册获取 API Key (免费版)
 *
 * 功能：
 * √ 自动定位
 * √ 天气预警
 * √ 实时天气 + 24h 预报
 * √ 生活指数
 *
 * 配置：
 * 1️⃣ 配置 MITM + 重写
 *    Quantumult X:
 *    [MITM]
 *    hostname=weather-data.apple.com, api.weather.com
 *    [rewrite_local]
 *    https:\/\/((weather-data\.apple)|(api\.weather))\.com url script-request-header https://raw.githubusercontent.com/YOUR-USERNAME/qweather-weather.js
 *
 *    Surge:
 *    [MITM]
 *    hostname=weather-data.apple.com, api.weather.com
 *    [Script]
 *    type=http-request, pattern=https:\/\/((weather-data\.apple)|(api\.weather))\.com, script-path=qweather-weather.js, require-body=false
 *
 * 2️⃣ 打开手机定位服务 > 天气 > 允许访问位置
 * 3️⃣ 在 box.js 或本地存储中设置：
 *    key → 和风天气 API Key
 *    location → 和风城市 ID（可选，不设置则自动定位）
 * 4️⃣ 配置 cron 定时任务，如：10 8-22/2 * * *
 */

/********************** SCRIPT START *********************************/
const $ = API("qweather");

// ============ 和风天气配置 ============
const QW_KEY = "your-api-key-here"; // ← 替换为你的和风天气 API Key
const QW_LOCATION = ""; // 和风城市 ID，不设置则自动定位（推荐留空）
const QW_LANG = "zh";

// ============ 定位（从系统天气请求中获取） ============
let savedLocation = $.read("location"); // { latitude, longitude }

if (typeof $request !== "undefined") {
  const url = $request.url;
  const res =
    url.match(/weather\/.*?\/(.*)\/(.*)\?/) ||
    url.match(/geocode\/([0-9.]*)\/([0-9.]*)\//) ||
    url.match(/geocode=([0-9.]*),([0-9.]*)/) ||
    url.match(/v2\/availability\/([0-9.]*)\/([0-9.]*)\//);

  if (res === null) {
    $.info(`❌ 无法从 URL 获取位置: ${url}`);
    $.done({ body: $request.body });
  } else {
    savedLocation = {
      latitude: res[1],
      longitude: res[2],
    };
    if (!$.read("saved")) {
      $.notify("[和风天气]", "", "🎉 获取定位成功");
    }
    $.write(res[1], "#latitude");
    $.write(res[2], "#longitude");
    $.write(savedLocation, "location");
    $.write("1", "saved");
    $.done({ body: $request.body });
  }
} else {
  // 定时任务
  !(async () => {
    if (!QW_KEY) {
      $.notify("[和风天气]", "❌ 未设置 API Key", "请前往 https://dev.qweather.com/ 注册获取\n并在脚本第 40 行填入 key");
      $.done();
      return;
    }
    if (!savedLocation) {
      $.notify("[和风天气]", "❌ 未获取到定位", "请确保 MITM 重写配置正确\n并开启手机定位服务");
      $.done();
      return;
    }
    await run();
    $.done();
  })();
}

// ============ 主流程 ============
async function run() {
  const { latitude, longitude } = savedLocation;

  // 1. 根据经纬度获取和风城市 ID
  const { locationId, locationName } = await geocode(latitude, longitude);

  // 2. 获取实时天气
  const now = await getNow(locationId);

  // 3. 获取 24h 预报
  const forecast24h = await getForecast24h(locationId);

  // 4. 获取天气预警
  const alerts = await getAlerts(locationId);

  // 5. 获取生活指数
  const indices = await getIndices(locationId);

  // 6. 组装通知
  let body = buildNotify(now, forecast24h, alerts, indices, locationName);
  $.notify("[和风天气]", locationName, body);
}

// ============ API 调用 ============
const QW_BASE = "https://devapi.qweather.com/v7";

async function getNow(id) {
  const url = `${QW_BASE}/weather/now?location=${id}&lang=${QW_LANG}&key=${QW_KEY}`;
  return $.http.get({ url })
    .then(r => JSON.parse(r.body))
    .then(d => {
      if (d.code !== "200") throw new Error(`getNow 错误: ${d.code}`);
      return d.now;
    });
}

async function getForecast24h(id) {
  const url = `${QW_BASE}/weather/24h?location=${id}&lang=${QW_LANG}&key=${QW_KEY}`;
  return $.http.get({ url })
    .then(r => JSON.parse(r.body))
    .then(d => {
      if (d.code !== "200") throw new Error(`getForecast 错误: ${d.code}`);
      return d.forecast;
    });
}

async function getAlerts(id) {
  const url = `${QW_BASE}/weather/alert?location=${id}&lang=${QW_LANG}&key=${QW_KEY}`;
  return $.http.get({ url })
    .then(r => JSON.parse(r.body))
    .then(d => {
      if (d.code !== "200") return [];
      return d.alert || [];
    })
    .catch(() => []);
}

async function getIndices(id) {
  const url = `${QW_BASE}/indices/1d?type=1&location=${id}&lang=${QW_LANG}&key=${QW_KEY}`;
  return $.http.get({ url })
    .then(r => JSON.parse(r.body))
    .then(d => {
      if (d.code !== "200") return [];
      return d.daily || [];
    })
    .catch(() => []);
}

async function geocode(lat, lon) {
  // 先尝试用经纬度反向解析城市
  const url = `https://geoapi.qweather.com/v2/city/geo?location=${lon},${lat}&key=${QW_KEY}`;
  const d = await $.http.get({ url })
    .then(r => JSON.parse(r.body));

  if (d.code === "200" && d.location && d.location.length > 0) {
    const loc = d.location[0];
    return {
      locationId: loc.id,
      locationName: `${loc.name} ${loc.adm2 || ""}`.trim(),
    };
  }
  throw new Error(`geocode 错误: ${d.code}`);
}

// ============ 通知组装 ============
function buildNotify(now, forecast, alerts, indices, locationName) {
  let lines = [];

  // 实时天气
  const icon = weatherIcon(now.icon);
  lines.push(`${icon} ${now.text}  ${now.temp}°C`);
  lines.push(`体感 ${now.feelsLike}°C  |  湿度 ${now.humidity}%  |  风向 ${windDir(now.windDir)} ${now.windScale}级`);
  lines.push(`气压 ${now.pressure}hPa  |  能见度 ${now.vis}km`);

  // 预警
  if (alerts.length > 0) {
    const alert = alerts[0];
    lines.push(`\n⚠️ [预警] ${alert.title}`);
    lines.push(`  ${alert.cate}  |  ${alert.startTime} 起`);
    if (alert.endTime) lines.push(`  至 ${alert.endTime}`);
    if (alert.content) lines.push(`  ${alert.content.substring(0, 60)}`);
  }

  // 24h 预报（取接下来几个时段）
  lines.push("\n📋 24h 预报：");
  const showPoints = forecast.filter((f, i) => {
    if (i === 0) return true;
    const hour = parseInt(f.fxTime.split("T")[1].split(":")[0]);
    return hour % 3 === 0 || i < 5;
  }).slice(0, 6);

  showPoints.forEach(f => {
    const time = f.fxTime.split("T")[1].substring(0, 5);
    const icon = weatherIcon(f.icon);
    lines.push(`  ${time}  ${icon} ${f.tempMax}°/${f.tempMin}° ${f.text}`);
  });

  // 生活指数（取前 3 个）
  if (indices.length > 0) {
    lines.push("\n📌 生活指数：");
    indices.slice(0, 4).forEach(idx => {
      lines.push(`  ${idx.name}: ${idx.brief}`);
    });
  }

  return lines.join("\n");
}

// ============ 工具函数 ============
function weatherIcon(icon) {
  const map = {
    "100": "☀️", "101": "☁️", "102": "⛅", "103": "⛅", "104": "☁️",
    "150": "☀️", "151": "☁️", "152": "⛅", "153": "⛅", "154": "☁️",
    "199": "",
    "300": "🌧", "301": "🌧", "302": "⛈", "303": "⛈", "304": "⛈",
    "305": "⛈", "306": "⛈", "307": "⛈", "308": "⛈", "309": "⛈",
    "310": "⛈", "311": "🌧", "312": "🌧", "313": "🌧", "314": "🌧",
    "315": "🌧", "316": "🌧", "317": "🌧", "318": "🌧",
    "350": "🌧", "351": "🌧", "399": "🌧",
    "400": "🌨", "401": "🌨", "402": "❄️", "403": "❄️", "404": "❄️",
    "405": "❄️", "406": "❄️", "407": "❄️", "408": "❄️", "409": "❄️",
    "410": "❄️", "456": "❄️", "457": "❄️", "499": "❄️",
    "500": "🌫", "501": "🌫", "502": "🌫", "503": "🌫", "504": "🌫",
    "505": "🌫", "507": "🌫", "508": "🌫", "509": "🌫", "510": "🌫",
    "511": "🌫", "512": "🌫", "513": "🌫", "514": "🌫", "515": "🌫",
  };
  return map[icon] || "🌤";
}

function windDir(dir) {
  const dirs = {
    "N": "北", "NE": "东北", "E": "东", "SE": "东南",
    "S": "南", "SW": "西南", "W": "西", "NW": "西北",
  };
  return dirs[dir] || dir;
}

// prettier-ignore
/*********************************** API (Chopper) *************************************/
function ENV() { const e = "undefined" != typeof $task, t = "undefined" != typeof $loon, s = "undefined" != typeof $httpClient && !t, i = "function" == typeof require && "undefined" != typeof $jsbox; return { isQX: e, isLoon: t, isSurge: s, isNode: "function" == typeof require && !i, isJSBox: i, isRequest: "undefined" != typeof $request, isScriptable: "undefined" != typeof importModule } }
function HTTP(e = { baseURL: "" }) { const { isQX: t, isLoon: s, isSurge: i, isNode: o, isJSBox: r, isScriptable: u } = ENV(); const a = /https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&\/\/=]*)/; const c = {}; return ["GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH"].forEach(l => c[l.toLowerCase()] = (function(l, a) { a = "string" == typeof a ? { url: a } : a; const c = e.baseURL; c && !a.url.match(a) && (a.url = c + a.url); const f = { ...e, ...a }; let d; if (t) d = $task.fetch({ method: l, ...a }); else if (s || i || o) d = new Promise((e, t) => { (o ? require("request") : $httpClient)[l.toLowerCase()](a, (s, i, n) => { s ? t(s) : e({ statusCode: i.status || i.statusCode, headers: i.headers, body: n }) }) }); else if (u) { const e = new Request(a.url); e.method = l, e.headers = a.headers, e.body = a.body, d = new Promise((t, s) => { e.loadString().then(s => { t({ statusCode: e.response.statusCode, headers: e.response.headers, body: s }) }).catch(e => s(e)) }) } return d })(l, a))), c }
function API(e = "untitled", t = !1) { const { isQX: s, isLoon: i, isSurge: n, isNode: o, isJSBox: r, isScriptable: u } = ENV(); return new class { constructor(e, t) { this.name = e, this.debug = t, this.http = HTTP(), this.env = ENV(), this.node = (() => { if (o) { return { fs: require("fs") } } return null })(), this.initCache(); Promise.prototype.delay = function (e) { return this.then(function (t) { return ((e, t) => new Promise(function (s) { setTimeout(s.bind(null, t), e) }))(e, t) }) } } initCache() { if (s && (this.cache = JSON.parse($prefs.valueForKey(this.name) || "{}")), (i || n) && (this.cache = JSON.parse($persistentStore.read(this.name) || "{}")), o) { let e = "root.json"; this.node.fs.existsSync(e) || this.node.fs.writeFileSync(e, JSON.stringify({}), { flag: "wx" }, e => console.log(e)), this.root = {}, e = `${this.name}.json`, this.node.fs.existsSync(e) ? this.cache = JSON.parse(this.node.fs.readFileSync(`${this.name}.json`)) : (this.node.fs.writeFileSync(e, JSON.stringify({}), { flag: "wx" }, e => console.log(e)), this.cache = {}) } } persistCache() { const e = JSON.stringify(this.cache, null, 2); s && $prefs.setValueForKey(e, this.name), (i || n) && $persistentStore.write(e, this.name), o && (this.node.fs.writeFileSync(`${this.name}.json`, e, { flag: "w" }, e => console.log(e)), this.node.fs.writeFileSync("root.json", JSON.stringify(this.root, null, 2), { flag: "w" }, e => console.log(e))) } write(e, t) { if (this.log(`SET ${t}`), -1 !== t.indexOf("#")) { if (t = t.substr(1), n || i) return $persistentStore.write(e, t); if (s) return $prefs.setValueForKey(e, t); o && (this.root[t] = e) } else this.cache[t] = e; this.persistCache() } read(e) { return this.log(`READ ${e}`), -1 === e.indexOf("#") ? this.cache[e] : (e = e.substr(1), n || i ? $persistentStore.read(e) : s ? $prefs.valueForKey(e) : o ? this.root[e] : void 0) } delete(e) { if (this.log(`DELETE ${e}`), -1 !== e.indexOf("#")) { if (e = e.substr(1), n || i) return $persistentStore.write(null, e); if (s) return $prefs.removeValueForKey(e); o && delete this.root[e] } else delete this.cache[e]; this.persistCache() } notify(e, t = "", l = "", h = {}) { const a = h["open-url"], c = h["media-url"]; if (s && $notify(e, t, l, h), n && $notification.post(e, t, l + `${c ? "\n多媒体:" + c : ""}`, { url: a }), i) { let s = {}; a && (s.openUrl = a), c && (s.mediaUrl = c), "{}" === JSON.stringify(s) ? $notification.post(e, t, l) : $notification.post(e, t, l, s) } if (o || u) { const s = l + (a ? `\n点击跳转: ${a}` : "") + (c ? `\n多媒体: ${c}` : ""); if (r) { require("push").schedule({ title: e, body: (t ? t + "\n" : "") + s }) } else console.log(`${e}\n${t}\n${s}\n\n`) } } log(e) { this.debug && console.log(`[${this.name}] LOG: ${this.stringify(e)}`) } info(e) { console.log(`[${this.name}] INFO: ${this.stringify(e)}`) } error(e) { console.log(`[${this.name}] ERROR: ${this.stringify(e)}`) } wait(e) { return new Promise(t => setTimeout(t, e)) } done(e = {}) { s || i || n ? $done(e) : o && !r && "undefined" != typeof $context && ($context.headers = e.headers, $context.statusCode = e.statusCode, $context.body = e.body) } stringify(e) { if ("string" == typeof e || e instanceof String) return e; try { return JSON.stringify(e, null, 2) } catch (e) { return "[object Object]" } } }(e, t) }
/*****************************************************************************/
