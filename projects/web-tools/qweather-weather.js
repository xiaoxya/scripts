/**
 * 和风天气 v1.1
 * @author: mo (based on Peng-YM's 彩云天气)
 *
 * 和风天气 API: https://dev.qweather.com/
 *
 * 功能：
 * - 从系统天气请求中自动保存经纬度
 * - 定时推送实时天气、24h 逐小时预报、天气预警、生活指数
 *
 * 配置：
 * 1. 配置 MITM + 重写，拦截 weather-data.apple.com / api.weather.com
 * 2. 打开手机定位服务 > 天气 > 允许访问位置
 * 3. 在 BoxJs / 本地存储中设置 key，或直接修改 QW_KEY
 * 4. 如需 Bark 推送，在本地存储中设置 barkKey，可选设置 barkServer
 * 5. 配置 cron 定时任务，如：10 8-22/2 * * *
 */

/********************** SCRIPT START *********************************/
const APP_NAME = "qweather";
const $ = API(APP_NAME);

// ============ 和风天气配置 ============
const QW_KEY = $.read("key") || "your-api-key-here";
const QW_LOCATION_ID = $.read("locationId") || ""; // 和风城市 ID，可选；留空则用自动定位的经纬度反查
const QW_LANG = $.read("lang") || "zh";
const QW_INDICES_TYPE = $.read("indicesType") || "1,2,3,5";
const BARK_KEY = $.read("barkKey") || "";
const BARK_SERVER = trimTrailingSlash($.read("barkServer") || "https://api.day.app");
const BARK_GROUP = $.read("barkGroup") || "和风天气";
const BARK_ICON = $.read("barkIcon") || "";
const BARK_SOUND = $.read("barkSound") || "";

const QW_API_BASE = "https://devapi.qweather.com/v7";
const QW_GEO_BASE = "https://geoapi.qweather.com/v2";
const NOTIFY_TITLE = "[和风天气]";

main();

function main() {
  if ($.env.isRequest) {
    handleLocationRequest();
    return;
  }

  runTask()
    .catch(async error => {
      $.error(error);
      await sendErrorNotify(error);
    })
    .finally(() => $.done());
}

// ============ 定位拦截 ============
function handleLocationRequest() {
  const location = parseLocationFromUrl($request.url);

  if (!location) {
    $.info(`无法从 URL 获取位置: ${$request.url}`);
    $.done({ body: $request.body });
    return;
  }

  saveLocation(location);
  $.done({ body: $request.body });
}

function parseLocationFromUrl(url) {
  const number = "(-?\\d+(?:\\.\\d+)?)";
  const patterns = [
    new RegExp(`weather\\/.*?\\/${number}\\/${number}\\?`),
    new RegExp(`geocode\\/${number}\\/${number}\\/`),
    new RegExp(`geocode=${number},${number}`),
    new RegExp(`v2\\/availability\\/${number}\\/${number}\\/`),
  ];

  for (const pattern of patterns) {
    const match = url.match(pattern);
    if (match) {
      return {
        latitude: match[1],
        longitude: match[2],
      };
    }
  }

  return null;
}

function saveLocation(location) {
  const previous = $.read("location");
  const shouldNotify = !$.read("saved");

  $.write(location.latitude, "#latitude");
  $.write(location.longitude, "#longitude");
  $.write(location, "location");
  $.write("1", "saved");

  if (shouldNotify || !sameLocation(previous, location)) {
    $.notify(NOTIFY_TITLE, "", `获取定位成功：${location.latitude}, ${location.longitude}`);
  }
}

function sameLocation(left, right) {
  return Boolean(
    left &&
    right &&
    String(left.latitude) === String(right.latitude) &&
    String(left.longitude) === String(right.longitude)
  );
}

// ============ 主流程 ============
async function runTask() {
  assertConfig();

  const place = await resolvePlace();
  const [now, forecast24h, alerts, indices] = await Promise.all([
    getNow(place.id),
    getForecast24h(place.id),
    getAlerts(place.id),
    getIndices(place.id),
  ]);

  const weather = { place, now, forecast24h, alerts, indices };
  await sendWeatherNotify(weather);
}

function assertConfig() {
  if (!QW_KEY || QW_KEY === "your-api-key-here") {
    throw new Error("未设置 API Key，请在 BoxJs / 本地存储写入 key，或直接修改脚本里的 QW_KEY。");
  }
}

async function resolvePlace() {
  if (QW_LOCATION_ID) {
    return {
      id: QW_LOCATION_ID,
      name: $.read("locationName") || QW_LOCATION_ID,
    };
  }

  const location = normalizeLocation($.read("location"));
  if (!location) {
    throw new Error("未获取到定位，请先打开系统天气 App，并确认 MITM 与重写配置已生效。");
  }

  return geocode(location);
}

function normalizeLocation(value) {
  if (!value) return null;

  if (typeof value === "string") {
    try {
      return normalizeLocation(JSON.parse(value));
    } catch (_) {
      return null;
    }
  }

  if (value.latitude && value.longitude) {
    return {
      latitude: String(value.latitude),
      longitude: String(value.longitude),
    };
  }

  return null;
}

// ============ API 调用 ============
async function qweatherGet(baseUrl, path, params) {
  const url = buildUrl(`${baseUrl}${path}`, {
    lang: QW_LANG,
    key: QW_KEY,
    ...params,
  });
  const response = await $.http.get({ url });

  if (response.statusCode && (response.statusCode < 200 || response.statusCode >= 300)) {
    throw new Error(`${path} HTTP ${response.statusCode}：${redactUrl(url)}`);
  }

  const body = response.body || "";
  if (!body.trim()) {
    throw new Error(`${path} 返回空内容，HTTP ${response.statusCode || "unknown"}：${redactUrl(url)}`);
  }

  const data = parseJson(body, path);

  if (data.code !== "200") {
    throw new Error(`${path} 请求失败：${data.code}`);
  }

  return data;
}

async function getNow(locationId) {
  const data = await qweatherGet(QW_API_BASE, "/weather/now", { location: locationId });
  return data.now;
}

async function getForecast24h(locationId) {
  const data = await qweatherGet(QW_API_BASE, "/weather/24h", { location: locationId });
  return data.hourly || [];
}

async function getAlerts(locationId) {
  try {
    const data = await qweatherGet(QW_API_BASE, "/warning/now", { location: locationId });
    return data.warning || [];
  } catch (error) {
    $.info(`天气预警获取失败，已跳过：${error.message || error}`);
    return [];
  }
}

async function getIndices(locationId) {
  try {
    const data = await qweatherGet(QW_API_BASE, "/indices/1d", {
      type: QW_INDICES_TYPE,
      location: locationId,
    });
    return data.daily || [];
  } catch (error) {
    $.info(`生活指数获取失败，已跳过：${error.message || error}`);
    return [];
  }
}

async function geocode(location) {
  const data = await qweatherGet(QW_GEO_BASE, "/city/lookup", {
    location: formatGeoLocation(location),
  });

  if (!data.location || data.location.length === 0) {
    throw new Error("经纬度反查城市失败：无匹配城市。");
  }

  const city = data.location[0];
  return {
    id: city.id,
    name: [city.name, city.adm2].filter(Boolean).join(" "),
  };
}

function buildUrl(base, params) {
  const query = Object.keys(params)
    .filter(key => params[key] !== undefined && params[key] !== null && params[key] !== "")
    .map(key => `${encodeURIComponent(key)}=${encodeURIComponent(params[key])}`)
    .join("&");

  return query ? `${base}?${query}` : base;
}

function redactUrl(url) {
  return url.replace(/([?&]key=)[^&]*/g, "$1***");
}

function formatGeoLocation(location) {
  const longitude = Number(location.longitude);
  const latitude = Number(location.latitude);

  if (!Number.isFinite(longitude) || !Number.isFinite(latitude)) {
    throw new Error(`定位经纬度无效：${location.longitude}, ${location.latitude}`);
  }

  return `${longitude.toFixed(2)},${latitude.toFixed(2)}`;
}

function parseJson(body, label) {
  try {
    return JSON.parse(body);
  } catch (error) {
    throw new Error(`${label} 返回内容不是有效 JSON：${error.message}`);
  }
}

// ============ 推送 ============
async function sendWeatherNotify(weather) {
  if (BARK_KEY) {
    await sendBarkNotify({
      title: `${weather.place.name}天气`,
      body: buildBarkBody(weather),
    });
    return;
  }

  $.notify(NOTIFY_TITLE, weather.place.name, buildNotify(weather));
}

async function sendErrorNotify(error) {
  const message = error.message || String(error);

  if (BARK_KEY) {
    try {
      await sendBarkNotify({
        title: "和风天气运行失败",
        body: `❌ 运行失败\n\n${message}`,
      });
      return;
    } catch (pushError) {
      $.error(pushError);
    }
  }

  $.notify(NOTIFY_TITLE, "运行失败", message);
}

async function sendBarkNotify({ title, body }) {
  const payload = {
    title,
    body,
    group: BARK_GROUP,
    isArchive: "1",
  };

  if (BARK_ICON) payload.icon = BARK_ICON;
  if (BARK_SOUND) payload.sound = BARK_SOUND;

  const response = await $.http.post({
    url: `${BARK_SERVER}/${encodeURIComponent(BARK_KEY)}`,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });

  if (response.statusCode && (response.statusCode < 200 || response.statusCode >= 300)) {
    throw new Error(`Bark 推送失败，HTTP ${response.statusCode}`);
  }

  const data = parseJson(response.body || "{}", "Bark");
  if (data.code && data.code !== 200) {
    throw new Error(`Bark 推送失败：${data.message || data.code}`);
  }
}

// ============ 通知组装 ============
function buildNotify({ now, forecast24h, alerts, indices }) {
  const lines = [];

  lines.push(formatNow(now));

  const alertLines = formatAlerts(alerts);
  if (alertLines.length > 0) {
    lines.push("", ...alertLines);
  }

  const forecastLines = formatForecast(forecast24h);
  if (forecastLines.length > 0) {
    lines.push("", "24h 预报：", ...forecastLines);
  }

  const indexLines = formatIndices(indices);
  if (indexLines.length > 0) {
    lines.push("", "生活指数：", ...indexLines);
  }

  return lines.join("\n");
}

function buildBarkBody({ now, forecast24h, alerts, indices }) {
  const forecastLines = formatBarkForecast(forecast24h);
  const alertLines = formatBarkAlerts(alerts);
  const indexLines = formatBarkIndices(indices);
  const lines = [
    `${weatherIcon(now.icon)} ${now.text}  ${now.temp}°C`,
    `🌡️ 体感 ${now.feelsLike}°C`,
    "",
    `💧 湿度 ${now.humidity}%`,
    `🌬️ ${windDir(now.windDir)} ${now.windScale}级`,
    `🧭 气压 ${now.pressure}hPa`,
    `👀 能见度 ${now.vis}km`,
  ];

  if (alertLines.length > 0) {
    lines.push("", "⚠️ 天气预警", ...alertLines);
  }

  if (forecastLines.length > 0) {
    lines.push("", "🕒 未来 24 小时", ...forecastLines);
  }

  if (indexLines.length > 0) {
    lines.push("", "🧭 生活指数", ...indexLines);
  }

  if (now.obsTime) {
    lines.push("", `📡 更新时间 ${formatDateTime(now.obsTime)}`);
  }

  return lines.join("\n");
}

function formatNow(now) {
  return [
    `${weatherIcon(now.icon)} ${now.text}  ${now.temp}°C`,
    `体感 ${now.feelsLike}°C  |  湿度 ${now.humidity}%  |  ${windDir(now.windDir)} ${now.windScale}级`,
    `气压 ${now.pressure}hPa  |  能见度 ${now.vis}km`,
  ].join("\n");
}

function formatAlerts(alerts) {
  if (!alerts || alerts.length === 0) return [];

  const alert = alerts[0];
  const lines = [`预警：${alert.title}`];

  if (alert.typeName || alert.severityColor || alert.startTime) {
    lines.push(`  ${[alert.typeName, alert.severityColor, alert.startTime && `${alert.startTime} 起`].filter(Boolean).join("  |  ")}`);
  }
  if (alert.endTime) lines.push(`  至 ${alert.endTime}`);
  if (alert.text) lines.push(`  ${truncate(alert.text, 60)}`);

  return lines;
}

function formatBarkAlerts(alerts) {
  if (!alerts || alerts.length === 0) return [];

  return alerts.slice(0, 2).flatMap(alert => {
    const meta = [alert.typeName, formatSeverity(alert.severityColor), alert.startTime && `${formatDateTime(alert.startTime)} 起`]
      .filter(Boolean)
      .join(" · ");
    const lines = [`• ${alert.title}`];
    if (meta) lines.push(`  ${meta}`);
    if (alert.text) lines.push(`  ${truncate(alert.text, 100)}`);
    return lines;
  });
}

function formatForecast(forecast) {
  return selectForecastPoints(forecast).map(item => {
    const time = item.fxTime.split("T")[1].substring(0, 5);
    return `  ${time}  ${weatherIcon(item.icon)} ${item.temp}° ${item.text}`;
  });
}

function formatBarkForecast(forecast) {
  return selectForecastPoints(forecast).map(item => {
    const time = item.fxTime.split("T")[1].substring(0, 5);
    const rain = item.pop ? ` · 降水 ${item.pop}%` : "";
    return `• ${time}  ${weatherIcon(item.icon)} ${item.temp}° ${item.text}${rain}`;
  });
}

function selectForecastPoints(forecast) {
  if (!Array.isArray(forecast)) return [];

  return forecast
    .filter((item, index) => {
      if (index === 0) return true;
      const hour = Number(item.fxTime.split("T")[1].split(":")[0]);
      return hour % 3 === 0 || index < 5;
    })
    .slice(0, 6);
}

function formatIndices(indices) {
  if (!Array.isArray(indices)) return [];

  return indices.slice(0, 4).map(index => `  ${index.name}: ${index.category || truncate(index.text || "", 20)}`);
}

function formatBarkIndices(indices) {
  if (!Array.isArray(indices)) return [];

  return indices.slice(0, 4).map(index => {
    const value = index.category || truncate(index.text || "", 20);
    return `• ${indexIcon(index.name)} ${index.name}：${value}`;
  });
}

function truncate(text, maxLength) {
  return text.length > maxLength ? `${text.substring(0, maxLength)}...` : text;
}

function trimTrailingSlash(value) {
  return String(value || "").replace(/\/+$/, "");
}

function formatDateTime(value) {
  return String(value || "")
    .replace("T", " ")
    .replace(/\+\d{2}:\d{2}$/, "")
    .replace(/:\d{2}$/, "");
}

function formatSeverity(color) {
  const map = {
    Red: "🔴 红色",
    Orange: "🟠 橙色",
    Yellow: "🟡 黄色",
    Blue: "🔵 蓝色",
    White: "⚪ 白色",
  };
  return map[color] || color;
}

function indexIcon(name) {
  if (name.indexOf("运动") !== -1) return "🏃";
  if (name.indexOf("洗车") !== -1) return "🚗";
  if (name.indexOf("穿衣") !== -1) return "👕";
  if (name.indexOf("紫外") !== -1) return "☀️";
  if (name.indexOf("感冒") !== -1) return "🤧";
  if (name.indexOf("空气") !== -1) return "🌫️";
  return "📌";
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

/*********************************** API *************************************/
function ENV() {
  const isQX = typeof $task !== "undefined";
  const isLoon = typeof $loon !== "undefined";
  const isSurge = typeof $httpClient !== "undefined" && !isLoon;
  const isJSBox = typeof require === "function" && typeof $jsbox !== "undefined";
  const isNode = typeof require === "function" && !isJSBox;

  return {
    isQX,
    isLoon,
    isSurge,
    isNode,
    isJSBox,
    isRequest: typeof $request !== "undefined",
    isScriptable: typeof importModule !== "undefined",
  };
}

function HTTP(options = { baseURL: "" }) {
  const env = ENV();
  const client = {};
  const methods = ["GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH"];

  methods.forEach(method => {
    client[method.toLowerCase()] = requestOptions => request(method, requestOptions);
  });

  function request(method, requestOptions) {
    const normalized = normalizeRequest(options, requestOptions);

    if (env.isQX) {
      return $task.fetch({ method, ...normalized });
    }

    if (env.isSurge || env.isLoon) {
      return requestWithHttpClient(method, normalized);
    }

    if (env.isScriptable) {
      return requestWithScriptable(method, normalized);
    }

    if (env.isNode) {
      return requestWithNode(method, normalized);
    }

    return Promise.reject(new Error("当前环境不支持 HTTP 请求。"));
  }

  return client;
}

function normalizeRequest(defaults, requestOptions) {
  const options = typeof requestOptions === "string" ? { url: requestOptions } : { ...requestOptions };

  if (defaults.baseURL && !/^https?:\/\//.test(options.url)) {
    options.url = defaults.baseURL + options.url;
  }

  const { baseURL: _baseURL, ...requestDefaults } = defaults;
  return { ...requestDefaults, ...options };
}

function requestWithHttpClient(method, options) {
  return new Promise((resolve, reject) => {
    $httpClient[method.toLowerCase()](options, (error, response, body) => {
      if (error) {
        reject(error);
        return;
      }

      resolve({
        statusCode: response.status || response.statusCode,
        headers: response.headers,
        body,
      });
    });
  });
}

function requestWithScriptable(method, options) {
  const request = new Request(options.url);
  request.method = method;
  request.headers = options.headers;
  request.body = options.body;

  return request.loadString().then(body => ({
    statusCode: request.response.statusCode,
    headers: request.response.headers,
    body,
  }));
}

async function requestWithNode(method, options) {
  if (typeof fetch !== "function") {
    throw new Error("本地 Node 环境需要 Node 18+，或提供全局 fetch。");
  }

  const response = await fetch(options.url, {
    method,
    headers: options.headers,
    body: options.body,
  });

  return {
    statusCode: response.status,
    headers: Object.fromEntries(response.headers.entries()),
    body: await response.text(),
  };
}

function API(name = "untitled", debug = false) {
  const env = ENV();

  return new class {
    constructor() {
      this.name = name;
      this.debug = debug;
      this.env = env;
      this.http = HTTP();
      this.node = env.isNode ? { fs: require("fs") } : null;
      this.root = {};
      this.cache = {};
      this.initCache();
    }

    initCache() {
      if (env.isQX) {
        this.cache = safeJsonParse($prefs.valueForKey(this.name), {});
        return;
      }

      if (env.isLoon || env.isSurge) {
        this.cache = safeJsonParse($persistentStore.read(this.name), {});
        return;
      }

      if (env.isNode) {
        this.root = this.readJsonFile("root.json");
        this.cache = this.readJsonFile(`${this.name}.json`);
      }
    }

    readJsonFile(file) {
      if (!this.node.fs.existsSync(file)) {
        this.node.fs.writeFileSync(file, JSON.stringify({}, null, 2), { flag: "wx" });
        return {};
      }

      return safeJsonParse(this.node.fs.readFileSync(file, "utf8"), {});
    }

    persistCache() {
      const body = JSON.stringify(this.cache, null, 2);

      if (env.isQX) {
        $prefs.setValueForKey(body, this.name);
      } else if (env.isLoon || env.isSurge) {
        $persistentStore.write(body, this.name);
      } else if (env.isNode) {
        this.node.fs.writeFileSync(`${this.name}.json`, body);
        this.node.fs.writeFileSync("root.json", JSON.stringify(this.root, null, 2));
      }
    }

    write(value, key) {
      this.log(`SET ${key}`);

      if (key.indexOf("#") !== -1) {
        return this.writeRoot(key.substring(1), value);
      }

      this.cache[key] = value;
      this.persistCache();
      return true;
    }

    writeRoot(key, value) {
      if (env.isLoon || env.isSurge) return $persistentStore.write(value, key);
      if (env.isQX) return $prefs.setValueForKey(value, key);

      if (env.isNode) {
        this.root[key] = value;
        this.persistCache();
        return true;
      }

      return false;
    }

    read(key) {
      this.log(`READ ${key}`);

      if (key.indexOf("#") !== -1) {
        return this.readRoot(key.substring(1));
      }

      return this.cache[key];
    }

    readRoot(key) {
      if (env.isLoon || env.isSurge) return $persistentStore.read(key);
      if (env.isQX) return $prefs.valueForKey(key);
      if (env.isNode) return this.root[key];
      return undefined;
    }

    delete(key) {
      this.log(`DELETE ${key}`);

      if (key.indexOf("#") !== -1) {
        return this.deleteRoot(key.substring(1));
      }

      delete this.cache[key];
      this.persistCache();
      return true;
    }

    deleteRoot(key) {
      if (env.isLoon || env.isSurge) return $persistentStore.write(null, key);
      if (env.isQX) return $prefs.removeValueForKey(key);

      if (env.isNode) {
        delete this.root[key];
        this.persistCache();
        return true;
      }

      return false;
    }

    notify(title, subtitle = "", body = "", options = {}) {
      const openUrl = options["open-url"];
      const mediaUrl = options["media-url"];

      if (env.isQX) {
        $notify(title, subtitle, body, options);
      } else if (env.isSurge) {
        $notification.post(title, subtitle, body + (mediaUrl ? `\n多媒体:${mediaUrl}` : ""), { url: openUrl });
      } else if (env.isLoon) {
        const loonOptions = {};
        if (openUrl) loonOptions.openUrl = openUrl;
        if (mediaUrl) loonOptions.mediaUrl = mediaUrl;
        $notification.post(title, subtitle, body, loonOptions);
      } else if (env.isJSBox) {
        require("push").schedule({ title, body: (subtitle ? `${subtitle}\n` : "") + body });
      } else {
        console.log(`${title}\n${subtitle}\n${body}\n`);
      }
    }

    log(message) {
      if (this.debug) console.log(`[${this.name}] LOG: ${this.stringify(message)}`);
    }

    info(message) {
      console.log(`[${this.name}] INFO: ${this.stringify(message)}`);
    }

    error(message) {
      console.log(`[${this.name}] ERROR: ${this.stringify(message)}`);
    }

    done(value = {}) {
      if (env.isQX || env.isLoon || env.isSurge) {
        $done(value);
      } else if (env.isNode && typeof $context !== "undefined") {
        $context.headers = value.headers;
        $context.statusCode = value.statusCode;
        $context.body = value.body;
      }
    }

    stringify(value) {
      if (value instanceof Error) return value.stack || value.message;
      if (typeof value === "string" || value instanceof String) return value;
      try {
        return JSON.stringify(value, null, 2);
      } catch (_) {
        return "[object Object]";
      }
    }
  }();
}

function safeJsonParse(value, fallback) {
  if (!value) return fallback;

  try {
    return JSON.parse(value);
  } catch (_) {
    return fallback;
  }
}

/*****************************************************************************/
