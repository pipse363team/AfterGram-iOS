const topicPattern = /^[-_A-Za-z0-9]{1,64}$/;

export function validateNtfyConfiguration(config) {
  const serverUrl = String(config?.serverUrl ?? '').replace(/\/+$/, '');
  let parsed;
  try { parsed = new URL(serverUrl); } catch { throw new Error('NTFY_SERVER_URL must be an absolute HTTPS URL'); }
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.search || parsed.hash || parsed.pathname !== '/') {
    throw new Error('NTFY_SERVER_URL must be an HTTPS origin without credentials, path, query, or fragment');
  }
  if (typeof config.topic !== 'string' || !topicPattern.test(config.topic) || config.topic.length !== 64 || !/^[a-f0-9]{64}$/.test(config.topic)) {
    throw new Error('NTFY_TOPIC must be a 64-character lowercase hexadecimal secret');
  }
  const avatarBaseUrl = config?.avatarBaseUrl === undefined ? undefined : String(config.avatarBaseUrl).replace(/\/+$/, '');
  if (avatarBaseUrl !== undefined) {
    let parsedAvatarBase;
    try { parsedAvatarBase = new URL(avatarBaseUrl); } catch { throw new Error('NTFY_ATTACHMENT_BASE_URL must be an HTTPS origin'); }
    if (parsedAvatarBase.protocol !== 'https:' || parsedAvatarBase.username || parsedAvatarBase.password ||
      parsedAvatarBase.search || parsedAvatarBase.hash || parsedAvatarBase.pathname !== '/') {
      throw new Error('NTFY_ATTACHMENT_BASE_URL must be an HTTPS origin without credentials, path, query, or fragment');
    }
  }
  return { serverUrl, topic: config.topic, ...(avatarBaseUrl ? { avatarBaseUrl } : {}) };
}

export function createNtfyPublisher(config, fetchImpl = fetch) {
  const settings = validateNtfyConfiguration(config);
  return {
    getClientConfiguration() {
      return {
        serverUrl: settings.serverUrl,
        topic: settings.topic,
        subscriptionUrl: `${settings.serverUrl}/${settings.topic}`,
      };
    },
    async send(payload) {
      const title = String(payload?.title ?? '').replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, 120);
      const description = String(payload?.description ?? '').slice(0, 500);
      if (!title || !description) throw new Error('ntfy notification title and body are required');

      const headers = {
        'content-type': 'application/json; charset=utf-8',
      };
      const custom = payload.custom;
      let click;
      if (custom !== undefined) {
        if (!custom || !['user', 'group', 'channel'].includes(custom.peer_type) ||
          typeof custom.peer_id !== 'string' || !/^\d{1,20}$/.test(custom.peer_id) ||
          typeof custom.message_id !== 'string' || !/^\d{1,12}$/.test(custom.message_id)) {
          throw new Error('Invalid Telegram notification route');
        }
        const target = new URL('tgretention://open');
        target.search = new URLSearchParams({
          peer_type: custom.peer_type,
          peer_id: custom.peer_id,
          message_id: custom.message_id,
        }).toString();
        click = target.href;
      }

      let attach;
      if (payload.avatarUrl !== undefined) {
        if (!settings.avatarBaseUrl) throw new Error('NTFY_ATTACHMENT_BASE_URL is not configured');
        let avatarUrl;
        try { avatarUrl = new URL(payload.avatarUrl); } catch { throw new Error('Invalid notification avatar URL'); }
        if (avatarUrl.origin !== settings.avatarBaseUrl || !/^\/v1\/notification-images\/[a-f0-9]{64}$/.test(avatarUrl.pathname)) {
          throw new Error('Invalid notification avatar URL');
        }
        attach = avatarUrl.href;
      }

      const response = await fetchImpl(settings.serverUrl, {
        method: 'POST',
        headers,
        body: JSON.stringify({ topic: settings.topic, title, message: description, ...(click ? { click } : {}), ...(attach ? { attach } : {}) }),
      });
      if (!response.ok) throw new Error(`ntfy returned HTTP ${response.status}`);
      return { sent: 1, failed: 0 };
    },
  };
}
