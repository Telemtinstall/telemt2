const nf = new Intl.NumberFormat('ru-RU');
const regionNames = typeof Intl.DisplayNames === 'function' ? new Intl.DisplayNames(['ru'], {type: 'region'}) : null;
const names = {'/api/v1/session': 'Сессии', '/api/v1/up': 'Отправка', '/api/v1/down': 'Получение', '/api/v1/ws': 'WebSocket'};
const reasonNames = {capacity_or_backpressure: 'Лимит или обратное давление', rejected_request: 'Запрос отклонён', server_error: 'Ошибка сервера', unexpected_status: 'Неожиданный HTTP-статус'};
let selected = '1h';
let latestData = null;
const geoSelection = {country: '', countryLabel: '', city: '', region: '', provider: '', asn: ''};

const bytes = n => n < 1024 ? n + ' Б' : n < 1048576 ? (n / 1024).toFixed(1) + ' КБ' : n < 1073741824 ? (n / 1048576).toFixed(1) + ' МБ' : (n / 1073741824).toFixed(2) + ' ГБ';
const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
const countryName = row => {
  try {
    if (regionNames && /^[A-Z]{2}$/.test(row.code) && row.code !== 'ZZ') return regionNames.of(row.code);
  } catch (_) {}
  return row.country && row.country.length > 2 ? row.country : row.code;
};

function resetGeoSelection() {
  Object.assign(geoSelection, {country: '', countryLabel: '', city: '', region: '', provider: '', asn: ''});
}

function countryTiles(id, rows) {
  const box = document.getElementById(id);
  box.innerHTML = rows.length ? '' : '<div class="empty">Событий за период нет</div>';
  rows.forEach(row => {
    const label = countryName(row);
    const element = document.createElement('button');
    element.type = 'button';
    element.className = 'tile clickable' + (geoSelection.country === row.code ? ' active' : '');
    element.title = `${label} · показать города`;
    element.innerHTML = `<b>${esc(label)} · ${esc(row.code)}</b><strong>${nf.format(row.connections)}</strong><small>${nf.format(row.unique_ips)} IP · ${bytes(row.bytes_in + row.bytes_out)}<br>Нажмите: показать города</small>`;
    element.addEventListener('click', () => {
      if (geoSelection.country === row.code) resetGeoSelection();
      else Object.assign(geoSelection, {country: row.code, countryLabel: label, city: '', region: '', provider: '', asn: ''});
      rerenderGeo();
    });
    box.appendChild(element);
  });
}

function aggregateCities(rows) {
  const grouped = new Map();
  rows.forEach(row => {
    const key = [row.code, row.city, row.region].join('\u0000');
    if (!grouped.has(key)) grouped.set(key, {city: row.city, region: row.region, country: row.country, code: row.code, connections: 0, traffic: 0, unique_ips: 0});
    const city = grouped.get(key);
    city.connections += row.connections;
    city.traffic += row.traffic;
    city.unique_ips += 1;
  });
  return [...grouped.values()].sort((a, b) => b.connections - a.connections);
}

function aggregateProviders(rows) {
  const grouped = new Map();
  rows.forEach(row => {
    const providerName = row.provider || 'Провайдер не определён';
    const key = [providerName, row.asn || ''].join('\u0000');
    if (!grouped.has(key)) grouped.set(key, {provider: providerName, asn: row.asn || '', connections: 0, traffic: 0, unique_ips: 0});
    const provider = grouped.get(key);
    provider.connections += row.connections;
    provider.traffic += row.traffic;
    provider.unique_ips += 1;
  });
  return [...grouped.values()].sort((a, b) => b.connections - a.connections);
}

function cityTiles(rows) {
  const box = document.getElementById('cities');
  box.innerHTML = rows.length ? '' : '<div class="empty">Города ещё не определены</div>';
  rows.forEach(row => {
    const active = geoSelection.country === row.code && geoSelection.city === row.city && geoSelection.region === row.region;
    const element = document.createElement('button');
    element.type = 'button';
    element.className = 'tile clickable' + (active ? ' active' : '');
    element.title = `${row.city} · показать IP`;
    element.innerHTML = `<b>${esc(row.city)}</b><strong>${nf.format(row.connections)}</strong><small>${esc(row.region ? row.region + ' · ' : '')}${esc(countryName(row))} · ${esc(row.code)}<br>${nf.format(row.unique_ips)} IP · ${bytes(row.traffic)}<br>Нажмите: показать IP</small>`;
    element.addEventListener('click', () => {
      if (active) Object.assign(geoSelection, {city: '', region: '', provider: '', asn: ''});
      else Object.assign(geoSelection, {country: row.code, countryLabel: countryName(row), city: row.city, region: row.region, provider: '', asn: ''});
      rerenderGeo();
    });
    box.appendChild(element);
  });
}

function providerTiles(rows) {
  const box = document.getElementById('providers');
  box.innerHTML = rows.length ? '' : '<div class="empty">Провайдеры ещё не определены</div>';
  rows.forEach(row => {
    const active = geoSelection.provider === row.provider && geoSelection.asn === row.asn;
    const element = document.createElement('button');
    element.type = 'button';
    element.className = 'tile clickable' + (active ? ' active' : '');
    element.title = `${row.provider} · показать IP`;
    element.innerHTML = `<b>${esc(row.provider)}</b><strong>${nf.format(row.connections)}</strong><small>${esc(row.asn || 'ASN неизвестен')} · ${nf.format(row.unique_ips)} IP<br>${bytes(row.traffic)}<br>Нажмите: показать IP</small>`;
    element.addEventListener('click', () => {
      if (active) Object.assign(geoSelection, {provider: '', asn: ''});
      else Object.assign(geoSelection, {provider: row.provider, asn: row.asn});
      rerenderGeo();
    });
    box.appendChild(element);
  });
}

function ipTiles(rows, geoEnabled) {
  const box = document.getElementById('ips');
  box.innerHTML = rows.length ? '' : '<div class="empty">IP по выбранному фильтру нет</div>';
  rows.forEach(row => {
    const element = document.createElement('div');
    element.className = 'tile' + (row.errors ? ' error-ip' : '');
    const provider = geoEnabled ? (row.asn ? row.asn + ' · ' : '') + row.provider : '';
    const geo = geoEnabled ? `${esc(row.city)} · ${esc(countryName(row))} · ${esc(row.code)}<br>${esc(provider)}<br>` : '';
    element.innerHTML = `<b>${esc(row.ip)}</b><strong>${nf.format(row.connections)} операций</strong><small>${geo}${bytes(row.traffic)}${row.errors ? ' · ошибок ' + nf.format(row.errors) : ''}</small>`;
    box.appendChild(element);
  });
  document.getElementById('ipNote').textContent = nf.format(rows.length) + ' IP по выбранному фильтру';
}

function renderGeoFilter() {
  const bar = document.getElementById('geoFilter');
  const parts = [];
  if (geoSelection.country) parts.push(geoSelection.countryLabel || geoSelection.country);
  if (geoSelection.city) parts.push(geoSelection.city + (geoSelection.region ? ' · ' + geoSelection.region : ''));
  if (geoSelection.provider) parts.push(geoSelection.provider + (geoSelection.asn ? ' · ' + geoSelection.asn : ''));
  if (!parts.length) {
    bar.hidden = true;
    bar.replaceChildren();
    return;
  }
  const label = document.createElement('span');
  label.append('Выбрано: ');
  const strong = document.createElement('b');
  strong.textContent = parts.join(' → ');
  label.appendChild(strong);
  const reset = document.createElement('button');
  reset.type = 'button';
  reset.textContent = 'Сбросить фильтр';
  reset.addEventListener('click', () => { resetGeoSelection(); rerenderGeo(); });
  bar.replaceChildren(label, reset);
  bar.hidden = false;
}

function renderGeo(windowData, data) {
  countryTiles('goodCountries', windowData.geo.countries.good);
  countryTiles('failedCountries', windowData.geo.countries.failed);
  const allIps = windowData.geo.ips;
  const countryIps = geoSelection.country ? allIps.filter(row => row.code === geoSelection.country) : allIps;
  cityTiles(aggregateCities(countryIps));
  const cityIps = geoSelection.city ? countryIps.filter(row => row.city === geoSelection.city && row.region === geoSelection.region) : countryIps;
  providerTiles(aggregateProviders(cityIps));
  const providerIps = geoSelection.provider ? cityIps.filter(row => (row.provider || 'Провайдер не определён') === geoSelection.provider && (row.asn || '') === geoSelection.asn) : cityIps;
  ipTiles(providerIps, data.geo_status === 'active');
  renderGeoFilter();
}

function rerenderGeo() {
  if (!latestData) return;
  const windowData = latestData.windows[selected];
  if (latestData.geo_status === 'active' || latestData.geo_status === 'checking') renderGeo(windowData, latestData);
}

function tokenForm(data) {
  const error = data.geo_error ? `<div class="token-error">${esc(data.geo_error)}</div>` : '';
  const title = data.geo_status === 'invalid' || data.geo_status === 'error' ? 'Укажите другой IPinfo token' : 'Укажите IPinfo token для географии';
  return `<div class="geo-setup"><b>${title}</b>${error}<form id="ipinfoForm"><input id="ipinfoToken" type="password" autocomplete="off" spellcheck="false" placeholder="Вставьте IPinfo token" required minlength="8" maxlength="256"><button type="submit">Проверить и сохранить</button></form><div id="tokenResult" class="token-result"></div><small><a href="https://ipinfo.io/account/token" target="_blank" rel="noopener noreferrer">Получить token на IPinfo</a> · если IPinfo не возвращает город, используется ipwho.is</small></div>`;
}

function wireTokenForm() {
  const form = document.getElementById('ipinfoForm');
  if (!form) return;
  form.addEventListener('submit', async event => {
    event.preventDefault();
    const input = document.getElementById('ipinfoToken'), button = form.querySelector('button'), result = document.getElementById('tokenResult');
    const token = input.value.trim();
    button.disabled = true;
    result.className = 'token-result';
    result.textContent = 'Проверяем токен через IPinfo…';
    try {
      const response = await fetch('/anal/ipinfo-token', {method: 'POST', credentials: 'same-origin', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({token})});
      const payload = await response.json();
      if (!response.ok || !payload.ok) throw new Error(payload.error || `HTTP ${response.status}`);
      input.value = '';
      result.className = 'token-result success';
      result.textContent = payload.message;
      setTimeout(load, 2500);
    } catch (error) {
      result.className = 'token-result token-error';
      result.textContent = error.message || 'Не удалось сохранить токен.';
      button.disabled = false;
    }
  });
}

function render(data) {
  latestData = data;
  const windowData = data.windows[selected], latest = windowData.metrics.latest, period = windowData.metrics.period;
  const good = windowData.endpoints.good.reduce((sum, row) => sum + row.requests, 0), bad = windowData.endpoints.failed.reduce((sum, row) => sum + row.requests, 0);
  const traffic = (period.bytes_up_total || 0) + (period.bytes_down_total || 0), unique = new Set(windowData.geo.ips.map(row => row.ip)).size;
  const countryCount = data.geo_enabled ? new Set([...windowData.geo.countries.good, ...windowData.geo.countries.failed].filter(row => row.code !== 'ZZ').map(row => row.code)).size : 0;
  const statusLabel = data.geo_status === 'active' ? nf.format(countryCount) + ' стран' : data.geo_status === 'checking' ? 'проверяется' : data.geo_status === 'invalid' ? 'ошибка токена' : data.geo_status === 'error' ? 'ошибка IPinfo' : 'отключена';
  const cityNote = data.geo_city_available === false ? ' · города уточняются через ipwho.is' : '';
  document.getElementById('summary').innerHTML = `<div class="metric"><span>Активные сессии</span><strong>${nf.format(latest.sessions_live || 0)}</strong><small>${nf.format(latest.streams_live || 0)} активных потоков</small></div><div class="metric"><span>Создано сессий</span><strong>${nf.format(period.sessions_created_total || 0)}</strong><small>за выбранный период</small></div><div class="metric"><span>Полезный трафик</span><strong>${bytes(traffic)}</strong><small>в обе стороны</small></div><div class="metric"><span>География</span><strong>${statusLabel}</strong><small>${nf.format(unique)} IP в выборке${cityNote}</small></div>`;
  document.getElementById('goodTotal').textContent = nf.format(good);
  document.getElementById('failedTotal').textContent = nf.format(bad);
  if (data.geo_status === 'active' || data.geo_status === 'checking') {
    renderGeo(windowData, data);
  } else {
    resetGeoSelection();
    document.getElementById('goodCountries').innerHTML = tokenForm(data);
    document.getElementById('failedCountries').innerHTML = '<div class="empty">География появится после проверки IPinfo token</div>';
    document.getElementById('cities').innerHTML = '<div class="empty">Аналитика городов ожидает действующий IPinfo token</div>';
    document.getElementById('providers').innerHTML = '<div class="empty">Провайдеры и ASN появятся после проверки токена</div>';
    document.getElementById('ips').innerHTML = '<div class="empty">IP продолжают собираться без публикации географии</div>';
    document.getElementById('ipNote').textContent = 'страна → город → провайдер';
    document.getElementById('geoFilter').hidden = true;
    wireTokenForm();
  }

  const reasons = document.getElementById('reasons'), entries = Object.entries(windowData.reasons), max = Math.max(1, ...entries.map(row => row[1]));
  reasons.innerHTML = entries.length ? '' : '<div class="empty">Ошибок за период нет</div>';
  entries.forEach(([key, count]) => {
    const element = document.createElement('div');
    element.className = 'reason';
    element.innerHTML = `<span>${esc(reasonNames[key] || key)}</span><strong>${nf.format(count)}</strong><div><i style="width:${count / max * 100}%"></i></div>`;
    reasons.appendChild(element);
  });
  const body = document.getElementById('errors');
  body.innerHTML = '';
  windowData.errors.forEach(row => {
    const tableRow = document.createElement('tr'), geo = data.geo_status === 'active' ? [row.city, row.country, row.code].filter(Boolean).join(' · ') : '', provider = data.geo_status === 'active' ? [row.asn, row.provider].filter(Boolean).join(' · ') : '';
    tableRow.innerHTML = `<td>${new Date(row.time).toLocaleString('ru-RU')}</td><td>${esc(row.ip)}${geo ? '<br><small>' + esc(geo) + (provider ? '<br>' + esc(provider) : '') + '</small>' : ''}</td><td>${esc(names[row.endpoint] || row.endpoint)} · ${esc(row.method)}</td><td>${row.status} · ${esc(reasonNames[row.reason] || row.reason)}</td><td>${row.ms} мс · ${bytes(row.bytes_in + row.bytes_out)}</td>`;
    body.appendChild(tableRow);
  });
  if (!windowData.errors.length) body.innerHTML = '<tr><td colspan="5" class="empty">Ошибок за период нет</td></tr>';
  document.getElementById('updated').textContent = 'обновлено ' + new Date(data.generated_at).toLocaleTimeString('ru-RU');
}

async function load() {
  try {
    const response = await fetch('/anal/data.json?t=' + Date.now(), {cache: 'no-store'});
    if (!response.ok) throw new Error(response.status);
    render(await response.json());
  } catch (_) {
    document.getElementById('updated').textContent = 'ожидание данных';
  }
}

document.querySelectorAll('[data-window]').forEach(button => button.onclick = () => {
  selected = button.dataset.window;
  resetGeoSelection();
  document.querySelectorAll('[data-window]').forEach(item => item.classList.toggle('active', item === button));
  load();
});
load();
setInterval(load, 5000);
