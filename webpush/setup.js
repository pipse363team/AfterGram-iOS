(() => {
  const $ = (id) => document.getElementById(id);
  const isRu = navigator.language.toLowerCase().startsWith('ru');
  const savedServer = localStorage.getItem('aftergram.push.server');
  const savedToken = localStorage.getItem('aftergram.push.apiToken');
  if (savedServer) $('server').value = savedServer;
  if (savedToken) $('apiToken').value = savedToken;

  if (isRu) {
    document.documentElement.lang = 'ru';
    document.title = 'Уведомления AfterGram';
    $('eyebrow').textContent = 'Уведомления на iPhone';
    $('connectionHeading').textContent = 'Подключи сервер AfterGram';
    document.querySelector('.card-intro').textContent = 'Введи адрес сервера и токен владельца, чтобы получить закрытую тему ntfy.';
    document.querySelector('#setup .card-intro').textContent = 'Выполни три шага. Настроить нужно только один раз.';
    $('securityNote').textContent = 'Не сообщай никому токен владельца и имя закрытой темы. Чтобы удалить токен с этого устройства, очисти данные сайта в браузере.';
    $('heading').textContent = 'Уведомления AfterGram';
    $('intro').textContent = 'Установи ntfy на iPhone. Текст сообщений остаётся на твоём сервере; ntfy.sh передаёт только общий сигнал для пробуждения приложения.';
    $('serverLabel').textContent = 'Сервер AfterGram';
    $('tokenLabel').textContent = 'API-токен владельца';
    $('apiToken').placeholder = 'Вставь API-токен сервера';
    $('load').textContent = 'Получить настройки ntfy';
    $('setupHeading').textContent = 'Настрой ntfy на iPhone';
    $('stepInstall').textContent = 'Установи приложение ntfy.';
    $('stepServer').textContent = 'В ntfy открой Настройки → Сервер по умолчанию и введи адрес ниже без «/» на конце:';
    $('stepTopic').textContent = 'Вернись, нажми «+» → добавь подписку и вставь только имя темы ниже, без адреса сервера:';
    $('topicLabel').textContent = 'Имя закрытой темы:';
    $('topicNote').textContent = 'Название темы — секрет. Не пересылай его другим.';
    $('install').textContent = 'Установить ntfy из App Store';
    $('copy').textContent = 'Скопировать имя темы';
    $('test').textContent = 'Отправить тестовое уведомление';
    $('disableOld').textContent = 'Отключить старые Web Push уведомления';
    $('privacy').textContent = 'Эта страница сохраняет адрес сервера и API-токен только в браузере этого устройства. После настройки уведомления будут приходить через ntfy; нажатие должно открыть соответствующий чат AfterGram.';
  }

  function configuration() {
    const serverUrl = $('server').value.trim().replace(/\/+$/, '');
    const apiToken = $('apiToken').value.trim();
    let parsed;
    try { parsed = new URL(serverUrl); } catch { throw new Error(isRu ? 'Проверь адрес сервера.' : 'Check the server URL.'); }
    if (parsed.protocol !== 'https:' || parsed.username || parsed.password) throw new Error(isRu ? 'Адрес сервера должен использовать HTTPS.' : 'The server URL must use HTTPS.');
    if (!apiToken) throw new Error(isRu ? 'Введи API-токен владельца.' : 'Enter the owner API token.');
    return { serverUrl, apiToken };
  }

  async function ownerFetch(path, options = {}) {
    const config = configuration();
    const response = await fetch(`${config.serverUrl}${path}`, {
      ...options,
      headers: { ...(options.headers || {}), authorization: `Bearer ${config.apiToken}` },
      cache: 'no-store',
    });
    if (!response.ok) {
      if (response.status === 401) throw new Error(isRu ? 'API-токен не подошёл.' : 'The API token was rejected.');
      if (response.status === 404 && path === '/v1/ntfy-config') throw new Error(isRu ? 'Сервер ntfy ещё не настроен.' : 'ntfy is not configured on the server yet.');
      throw new Error(isRu ? `Сервер вернул ошибку ${response.status}.` : `The server returned error ${response.status}.`);
    }
    localStorage.setItem('aftergram.push.server', config.serverUrl);
    localStorage.setItem('aftergram.push.apiToken', config.apiToken);
    return response;
  }

  let ntfyConfig;
  $('load').addEventListener('click', async () => {
    $('status').textContent = '';
    try {
      const response = await ownerFetch('/v1/ntfy-config');
      ntfyConfig = await response.json();
      if (typeof ntfyConfig.serverUrl !== 'string' || typeof ntfyConfig.topic !== 'string' || !/^[a-f0-9]{64}$/.test(ntfyConfig.topic)) {
        throw new Error(isRu ? 'Сервер вернул некорректные настройки ntfy.' : 'The server returned invalid ntfy settings.');
      }
      $('ntfyServer').textContent = ntfyConfig.serverUrl;
      $('ntfyTopic').textContent = ntfyConfig.topic;
      $('setup').hidden = false;
      $('setupHeading').focus({ preventScroll: true });
      $('setup').scrollIntoView({ block: 'nearest' });
      $('status').textContent = isRu ? 'Настройки загружены. Добавь сервер и тему в ntfy.' : 'Settings loaded. Add the server and topic in ntfy.';
    } catch (error) {
      $('status').textContent = error.message || String(error);
    }
  });

  $('copy').addEventListener('click', async () => {
    if (!ntfyConfig) return;
    const value = ntfyConfig.topic;
    try {
      await navigator.clipboard.writeText(value);
      $('status').textContent = isRu ? 'Имя темы скопировано. Вставь его в форму подписки ntfy.' : 'Topic name copied. Paste it into the ntfy subscription form.';
    } catch {
      $('status').textContent = isRu ? 'Не удалось скопировать — выдели значения выше вручную.' : 'Could not copy; select the values above manually.';
    }
  });

  $('test').addEventListener('click', async () => {
    $('status').textContent = '';
    try {
      const response = await ownerFetch('/v1/send', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ title: 'AfterGram', description: isRu ? 'Тестовое уведомление ntfy' : 'ntfy test notification' }),
      });
      const result = await response.json();
      if (result.provider !== 'ntfy' || result.sent !== 1) throw new Error(isRu ? 'Сервер не подтвердил отправку через ntfy.' : 'The server did not confirm ntfy delivery.');
      $('status').textContent = isRu ? 'Тест отправлен. Проверь уведомление от ntfy.' : 'Test sent. Check for an ntfy notification.';
    } catch (error) {
      $('status').textContent = error.message || String(error);
    }
  });

  $('disableOld').addEventListener('click', async () => {
    $('status').textContent = '';
    try {
      if (!('serviceWorker' in navigator)) throw new Error(isRu ? 'На этом браузере старая Web Push-подписка не найдена.' : 'No old Web Push subscription is available in this browser.');
      const registrations = await navigator.serviceWorker.getRegistrations();
      const appScope = new URL('./', location.href).href;
      let removed = 0;
      for (const registration of registrations.filter(item => item.scope === appScope)) {
        const subscription = await registration.pushManager?.getSubscription();
        if (subscription) {
          await ownerFetch('/v1/unsubscribe', {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ endpoint: subscription.endpoint }),
          });
          await subscription.unsubscribe();
          removed++;
        }
        await registration.unregister();
      }
      $('status').textContent = isRu
        ? (removed ? 'Старая Web Push-подписка удалена.' : 'Старых Web Push-подписок на этом устройстве нет.')
        : (removed ? 'The old Web Push subscription was removed.' : 'There was no old Web Push subscription on this device.');
    } catch (error) {
      $('status').textContent = error.message || String(error);
    }
  });
})();
