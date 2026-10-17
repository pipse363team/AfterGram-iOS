    const $ = (id) => document.getElementById(id);
    const isRu = navigator.language.toLowerCase().startsWith('ru');
    if (isRu) {
      document.documentElement.lang = 'ru';
      $('intro').textContent = 'Подключи PWA к своему серверу push-уведомлений. Сначала добавь страницу на экран «Домой», затем укажи адрес сервера.';
      $('server').setAttribute('aria-label', 'Адрес сервера push'); $('apiToken').setAttribute('aria-label', 'Токен API сервера');
      $('server').placeholder = 'https://push.example.de'; $('apiToken').placeholder = 'API-токен сервера';
      $('subscribe').textContent = 'Включить уведомления'; $('test').textContent = 'Отправить тестовое уведомление'; $('disable').textContent = 'Отключить уведомления'; $('copy').textContent = 'Скопировать JSON подписки';
      $('output').setAttribute('aria-label', 'Push-подписка');
      document.querySelector('small').textContent = 'Приватный VAPID-ключ остаётся на твоём сервере. PWA передаёт серверу подписку и получает уведомления напрямую; нажатие откроет AfterGram. API-токен не сохраняется на странице. Требуется iOS/iPadOS 16.4 или новее.';
    }
    let subscriptionText = '';
    function decodeBase64Url(value) {
      const padded = value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - value.length % 4) % 4);
      return Uint8Array.from(atob(padded), character => character.charCodeAt(0));
    }
    function sameBytes(left, right) {
      return !!left && left.length === right.length && left.every((value, index) => value === right[index]);
    }
    function serverConfiguration() {
      const value = $('server').value.trim().replace(/\/+$/, '');
      const token = $('apiToken').value.trim();
      const url = new URL(value);
      if (url.protocol !== 'https:') throw new Error(isRu ? 'Адрес push-сервера должен использовать HTTPS.' : 'The push server URL must use HTTPS.');
      if (!token) throw new Error(isRu ? 'Введи API-токен сервера.' : 'Enter the server API token.');
      return { baseUrl: value, token };
    }
    async function register() {
      try {
        if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) throw new Error(isRu ? 'Этот браузер не поддерживает Web Push.' : 'Web Push is not supported by this browser.');
        const server = serverConfiguration();
        const permission = await Notification.requestPermission();
        if (permission !== 'granted') throw new Error(isRu ? 'Разреши уведомления в настройках iOS.' : 'Allow notifications in iOS settings.');
        const registration = await navigator.serviceWorker.register('./service-worker.js', { scope: './' });
        await navigator.serviceWorker.ready;
        const keyResponse = await fetch(`${server.baseUrl}/v1/vapid-public-key`, { cache: 'no-store' });
        if (!keyResponse.ok) throw new Error(isRu ? 'Не удалось получить VAPID-ключ с сервера.' : 'Could not get the VAPID key from the server.');
        const { publicKey } = await keyResponse.json();
        if (typeof publicKey !== 'string' || !publicKey) throw new Error(isRu ? 'Сервер вернул некорректный VAPID-ключ.' : 'The server returned an invalid VAPID key.');
        const applicationServerKey = decodeBase64Url(publicKey);
        if (applicationServerKey.length !== 65 || applicationServerKey[0] !== 4) throw new Error(isRu ? 'Некорректный публичный VAPID-ключ P-256.' : 'Invalid P-256 VAPID public key.');
        let subscription = await registration.pushManager.getSubscription();
        if (subscription && !sameBytes(subscription.options.applicationServerKey, applicationServerKey)) {
          await subscription.unsubscribe();
          subscription = null;
        }
        if (!subscription) subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey });
        const saveResponse = await fetch(`${server.baseUrl}/v1/subscriptions`, {
          method: 'POST',
          headers: { 'content-type': 'application/json', authorization: `Bearer ${server.token}` },
          body: JSON.stringify(subscription.toJSON()),
        });
        if (!saveResponse.ok) throw new Error(isRu ? 'Сервер не сохранил подписку. Проверь API-токен и настройки CORS.' : 'The server did not save the subscription. Check the API token and CORS settings.');
        const value = subscription.toJSON();
        if (!value.endpoint || !value.keys || !value.keys.p256dh || !value.keys.auth) throw new Error(isRu ? 'Браузер вернул неполную подписку.' : 'The browser returned an incomplete subscription.');
        subscriptionText = JSON.stringify({ endpoint: value.endpoint, keys: value.keys });
        $('output').value = subscriptionText; $('output').style.display = 'block'; $('copy').hidden = false;
        $('test').hidden = false; $('disable').hidden = false;
        $('status').textContent = isRu ? 'Готово. Подписка сохранена на твоём сервере.' : 'Ready. The subscription is saved on your server.';
      } catch (error) { $('status').textContent = error.message || String(error); }
    }
    $('subscribe').addEventListener('click', register);
    $('test').addEventListener('click', async () => {
      try {
        const server = serverConfiguration();
        const response = await fetch(`${server.baseUrl}/v1/send`, {
          method: 'POST',
          headers: { 'content-type': 'application/json', authorization: `Bearer ${server.token}` },
          body: JSON.stringify({ title: 'AfterGram', description: isRu ? 'Тестовое push-уведомление' : 'Test push notification' }),
        });
        if (!response.ok) throw new Error(isRu ? 'Сервер не отправил push-уведомление.' : 'The server could not send the push notification.');
        $('status').textContent = isRu ? 'Тестовое уведомление отправлено.' : 'Test notification sent.';
      } catch (error) { $('status').textContent = error.message || String(error); }
    });
    $('disable').addEventListener('click', async () => {
      try {
        const server = serverConfiguration();
        const registration = await navigator.serviceWorker.ready;
        const subscription = await registration.pushManager.getSubscription();
        if (subscription) {
          const response = await fetch(`${server.baseUrl}/v1/unsubscribe`, {
            method: 'POST',
            headers: { 'content-type': 'application/json', authorization: `Bearer ${server.token}` },
            body: JSON.stringify({ endpoint: subscription.endpoint }),
          });
          if (!response.ok) throw new Error(isRu ? 'Сервер не отключил подписку.' : 'The server could not remove the subscription.');
          await subscription.unsubscribe();
        }
        $('test').hidden = true; $('disable').hidden = true; $('copy').hidden = true;
        $('output').style.display = 'none';
        $('status').textContent = isRu ? 'Уведомления отключены.' : 'Notifications disabled.';
      } catch (error) { $('status').textContent = error.message || String(error); }
    });
    $('copy').addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(subscriptionText); $('status').textContent = isRu ? 'JSON подписки скопирован как резервная копия.' : 'Subscription JSON copied as a backup.'; }
      catch { $('output').focus(); $('output').select(); $('status').textContent = isRu ? 'Выдели и скопируй текст подписки вручную.' : 'Select and copy the subscription text manually.'; }
    });
    if ('serviceWorker' in navigator) navigator.serviceWorker.register('./service-worker.js', { scope: './' }).catch(() => {});
