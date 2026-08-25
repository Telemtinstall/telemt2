const nf = new Intl.NumberFormat('ru-RU');
const regionNames = typeof Intl.DisplayNames === 'function' ? new Intl.DisplayNames(['ru'], {type: 'region'}) : null;
const names = {'/api/v1/session': 'Сессии', '/api/v1/up': 'Отправка', '/api/v1/down': 'Получение', '/api/v1/ws': 'WebSocket'};
const reasonNames = {capacity_or_backpressure: 'Лимит или обратное давление', rejected_request: 'Запрос отклонён', server_error: 'Ошибка сервера', unexpected_status: 'Неожиданный HTTP-статус'};
let selected = '1h';

const bytes = n => n < 1024 ? n + ' Б' : n < 1048576 ? (n / 1024).toFixed(1) + ' КБ' : n < 1073741824 ? (n / 1048576).toFixed(1) + ' МБ' : (n / 1073741824).toFixed(2) + ' ГБ';
const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
const countryName = r => r.country && r.country.length > 2 ? r.country : (regionNames && r.code !== 'ZZ' ? regionNames.of(r.code) : r.code);

function countryTiles(id, rows) {
  const box = document.getElementById(id);
  box.innerHTML = rows.length ? '' : '<div class="empty">Событий за период нет</div>';
  rows.forEach(r => {
    const e = document.createElement('div'), label = countryName(r);
    e.className = 'tile';
    e.title = `${label} · ${nf.format(r.connections)} операций`;
    e.innerHTML = `<b>${esc(label)} · ${esc(r.code)}</b><strong>${nf.format(r.connections)}</strong><small>${nf.format(r.unique_ips)} IP · ${bytes(r.bytes_in + r.bytes_out)}</small>`;
    box.appendChild(e);
  });
}

function cityTiles(rows) {
  const box = document.getElementById('cities');
  box.innerHTML = rows.length ? '' : '<div class="empty">Геоданные ещё собираются</div>';
  rows.forEach(r => {
    const e = document.createElement('div');
    e.className = 'tile';
    e.innerHTML = `<b>${esc(r.city)}</b><strong>${nf.format(r.connections)}</strong><small>${esc(r.region ? r.region + ' · ' : '')}${esc(r.country)} · ${esc(r.code)}<br>${nf.format(r.unique_ips)} IP · ${bytes(r.traffic)}</small>`;
    box.appendChild(e);
  });
}

function ipTiles(rows, geoEnabled) {
  const box = document.getElementById('ips');
  box.innerHTML = rows.length ? '' : '<div class="empty">IP за период нет</div>';
  rows.forEach(r => {
    const e = document.createElement('div');
    e.className = 'tile' + (r.errors ? ' error-ip' : '');
    const provider = geoEnabled ? (r.asn ? r.asn + ' · ' : '') + r.provider : '';
    const geo = geoEnabled ? `${esc(r.city)} · ${esc(r.country)} · ${esc(r.code)}<br>${esc(provider)}<br>` : '';
    e.innerHTML = `<b>${esc(r.ip)}</b><strong>${nf.format(r.connections)} операций</strong><small>${geo}${bytes(r.traffic)}${r.errors ? ' · ошибок ' + nf.format(r.errors) : ''}</small>`;
    box.appendChild(e);
  });
}

function tokenForm(data) {
  const error = data.geo_error ? `<div class="token-error">${esc(data.geo_error)}</div>` : '';
  const title = data.geo_status === 'invalid' || data.geo_status === 'error' ? 'Укажите другой IPinfo token' : 'Укажите IPinfo token для географии';
  return `<div class="geo-setup"><b>${title}</b>${error}<form id="ipinfoForm"><input id="ipinfoToken" type="password" autocomplete="off" spellcheck="false" placeholder="Вставьте IPinfo token" required minlength="8" maxlength="256"><button type="submit">Проверить и сохранить</button></form><div id="tokenResult" class="token-result"></div><small><a href="https://ipinfo.io/account/token" target="_blank" rel="noopener noreferrer">Получить token на IPinfo</a> · города зависят от тарифа</small></div>`;
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
  const w = data.windows[selected], latest = w.metrics.latest, period = w.metrics.period;
  const good = w.endpoints.good.reduce((s, r) => s + r.requests, 0), bad = w.endpoints.failed.reduce((s, r) => s + r.requests, 0);
  const traffic = (period.bytes_up_total || 0) + (period.bytes_down_total || 0), unique = new Set(w.geo.ips.map(x => x.ip)).size;
  const countryCount = data.geo_enabled ? new Set([...w.geo.countries.good, ...w.geo.countries.failed].filter(x => x.code !== 'ZZ').map(x => x.code)).size : 0;
  const statusLabel = data.geo_status === 'active' ? nf.format(countryCount) + ' стран' : data.geo_status === 'checking' ? 'проверяется' : data.geo_status === 'invalid' ? 'ошибка токена' : data.geo_status === 'error' ? 'ошибка IPinfo' : 'отключена';
  const cityNote = data.geo_city_available === false ? ' · города недоступны на тарифе' : '';
  document.getElementById('summary').innerHTML = `<div class="metric"><span>Активные сессии</span><strong>${nf.format(latest.sessions_live || 0)}</strong><small>${nf.format(latest.streams_live || 0)} активных потоков</small></div><div class="metric"><span>Создано сессий</span><strong>${nf.format(period.sessions_created_total || 0)}</strong><small>за выбранный период</small></div><div class="metric"><span>Полезный трафик</span><strong>${bytes(traffic)}</strong><small>в обе стороны</small></div><div class="metric"><span>География</span><strong>${statusLabel}</strong><small>${nf.format(unique)} IP в выборке${cityNote}</small></div>`;
  document.getElementById('goodTotal').textContent = nf.format(good);
  document.getElementById('failedTotal').textContent = nf.format(bad);
  if (data.geo_status === 'active' || data.geo_status === 'checking') {
    countryTiles('goodCountries', w.geo.countries.good);
    countryTiles('failedCountries', w.geo.countries.failed);
    cityTiles(w.geo.cities);
  } else {
    document.getElementById('goodCountries').innerHTML = tokenForm(data);
    document.getElementById('failedCountries').innerHTML = '<div class="empty">География появится после проверки IPinfo token</div>';
    document.getElementById('cities').innerHTML = '<div class="empty">Аналитика городов ожидает действующий IPinfo token</div>';
    wireTokenForm();
  }
  ipTiles(w.geo.ips, data.geo_status === 'active');

  const reasons = document.getElementById('reasons'), entries = Object.entries(w.reasons), max = Math.max(1, ...entries.map(x => x[1]));
  reasons.innerHTML = entries.length ? '' : '<div class="empty">Ошибок за период нет</div>';
  entries.forEach(([key, n]) => {
    const e = document.createElement('div');
    e.className = 'reason';
    e.innerHTML = `<span>${esc(reasonNames[key] || key)}</span><strong>${nf.format(n)}</strong><div><i style="width:${n / max * 100}%"></i></div>`;
    reasons.appendChild(e);
  });
  const body = document.getElementById('errors');
  body.innerHTML = '';
  w.errors.forEach(r => {
    const tr = document.createElement('tr'), geo = data.geo_status === 'active' ? [r.city, r.country, r.code].filter(Boolean).join(' · ') : '', provider = data.geo_status === 'active' ? [r.asn, r.provider].filter(Boolean).join(' · ') : '';
    tr.innerHTML = `<td>${new Date(r.time).toLocaleString('ru-RU')}</td><td>${esc(r.ip)}${geo ? '<br><small>' + esc(geo) + (provider ? '<br>' + esc(provider) : '') + '</small>' : ''}</td><td>${esc(names[r.endpoint] || r.endpoint)} · ${esc(r.method)}</td><td>${r.status} · ${esc(reasonNames[r.reason] || r.reason)}</td><td>${r.ms} мс · ${bytes(r.bytes_in + r.bytes_out)}</td>`;
    body.appendChild(tr);
  });
  if (!w.errors.length) body.innerHTML = '<tr><td colspan="5" class="empty">Ошибок за период нет</td></tr>';
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
  document.querySelectorAll('[data-window]').forEach(x => x.classList.toggle('active', x === button));
  load();
});
load();
setInterval(load, 5000);
