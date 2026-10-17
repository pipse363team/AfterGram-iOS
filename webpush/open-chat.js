(() => {
  const isRu = navigator.language.toLowerCase().startsWith('ru');
  try {
    const request = indexedDB.open('aftergram-webpush', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('handoff');
    request.onsuccess = () => {
      const db = request.result;
      const transaction = db.transaction('handoff', 'readwrite');
      transaction.objectStore('handoff').delete('pending-chat');
      transaction.oncomplete = () => db.close();
    };
  } catch {}
  const params = new URLSearchParams(location.search);
  const peerType = params.get('peer_type');
  const peerId = params.get('peer_id');
  const messageId = params.get('message_id') || '0';
  if (!['user', 'group', 'channel'].includes(peerType) || !/^\d{1,20}$/.test(peerId || '') || !/^\d{1,12}$/.test(messageId)) {
    document.getElementById('title').textContent = isRu ? 'Не удалось определить чат.' : 'Could not identify the chat.';
    document.getElementById('hint').textContent = '';
    document.getElementById('open').hidden = true;
    return;
  }

  const target = new URL('tgretention://open');
  target.search = new URLSearchParams({ peer_type: peerType, peer_id: peerId, message_id: messageId }).toString();
  const openLink = document.getElementById('open');
  openLink.href = target.href;
  if (isRu) {
    document.documentElement.lang = 'ru';
    document.getElementById('title').textContent = 'Чат найден';
    document.getElementById('hint').textContent = 'Если iPhone не открыл AfterGram автоматически, нажми кнопку ниже.';
    openLink.textContent = 'Открыть чат в AfterGram';
  }
})();
