import { chmod, mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { stdin, stdout } from 'node:process';
import { pathToFileURL } from 'node:url';
import { Api, TelegramClient } from 'teleproto';
import { StringSession } from 'teleproto/sessions';
import { NewMessage } from 'teleproto/events';

const DEFAULT_SESSION_PATH = '/var/lib/aftergram-telegram/telegram.session';

function requiredEnv(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function telegramApiId() {
  const apiId = Number(requiredEnv('TELEGRAM_API_ID'));
  if (!Number.isSafeInteger(apiId) || apiId <= 0) throw new Error('TELEGRAM_API_ID must be a positive integer');
  return apiId;
}

function peerRoute(peer) {
  if (!peer) return undefined;
  let peerType;
  let rawId;
  switch (peer.className) {
    case 'PeerUser': peerType = 'user'; rawId = peer.userId; break;
    case 'PeerChat': peerType = 'group'; rawId = peer.chatId; break;
    case 'PeerChannel': peerType = 'channel'; rawId = peer.channelId; break;
    default: return undefined;
  }
  const peerId = rawId?.toString();
  if (!peerId || !/^\d{1,20}$/.test(peerId)) return undefined;
  return { peer_type: peerType, peer_id: peerId };
}

function displayName(entity) {
  if (!entity) return '';
  const name = [entity.firstName, entity.lastName].filter(Boolean).join(' ').trim();
  return name || entity.title || entity.username || '';
}

function mediaLabel(media) {
  const kind = media?.className ?? '';
  if (kind.includes('Photo')) return 'Photo';
  if (kind.includes('Poll')) return 'Poll';
  if (kind.includes('Geo')) return 'Location';
  if (kind.includes('Contact')) return 'Contact';
  const document = media?.document;
  const mime = document?.mimeType ?? '';
  if (mime.startsWith('video/')) return 'Video';
  if (mime.startsWith('audio/')) return 'Voice message';
  if (document) return 'File';
  return 'New message';
}

async function cachedProfilePhoto(client, entity, key, cache) {
  if (!client?.downloadProfilePhoto || !entity || !cache) return undefined;
  const now = Date.now();
  const cached = cache.get(key);
  if (cached && cached.expiresAt > now) return cached.promise;
  const promise = (async () => {
    try {
      const photo = await client.downloadProfilePhoto(entity, { isBig: false });
      if (!Buffer.isBuffer(photo) || photo.length > 128 * 1024) return undefined;
      const isJpeg = photo.length >= 3 && photo[0] === 0xff && photo[1] === 0xd8 && photo[2] === 0xff;
      const isPng = photo.length >= 8 && photo.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
      return isJpeg || isPng ? photo.toString('base64') : undefined;
    } catch {
      return undefined;
    }
  })();
  if (cache.size >= 500) cache.delete(cache.keys().next().value);
  cache.set(key, { promise, expiresAt: now + 24 * 60 * 60 * 1000 });
  return promise;
}

export async function formatTelegramNotification(event, { client, avatarCache } = {}) {
  const message = event?.message;
  if (!message || message.out || !Number.isSafeInteger(message.id) || message.id <= 0) return undefined;
  const custom = peerRoute(message.peerId);
  if (!custom) return undefined;

  const [chat, sender] = await Promise.all([
    typeof event.getChat === 'function' ? event.getChat() : Promise.resolve(event.chat),
    typeof message.getSender === 'function' ? message.getSender() : Promise.resolve(message.sender),
  ]);
  const senderName = displayName(sender);
  const isPrivate = event.isPrivate === true || custom.peer_type === 'user';
  const title = isPrivate ? senderName || 'Telegram' : displayName(chat) || 'Telegram';
  const text = String(message.message ?? message.text ?? '').trim();
  const content = text || mediaLabel(message.media);
  const description = isPrivate || !senderName ? content : `${senderName}: ${content}`;
  custom.message_id = String(message.id);
  const avatarEntity = isPrivate ? sender ?? chat : chat ?? sender;
  let avatar = await cachedProfilePhoto(client, avatarEntity, `${custom.peer_type}:${custom.peer_id}`, avatarCache);
  if (!avatar && sender && sender !== avatarEntity) {
    avatar = await cachedProfilePhoto(client, sender, `sender:${String(sender.id ?? `${custom.peer_id}:${message.id}`)}`, avatarCache);
  }
  return { title: title.slice(0, 120), description: description.slice(0, 500), ...(avatar ? { avatar } : {}), custom };
}

export async function isTelegramChatMuted(client, event, { cache = new Map(), nowSeconds = Math.floor(Date.now() / 1000) } = {}) {
  const route = peerRoute(event?.message?.peerId);
  if (!route) return false;
  const chat = typeof event.getChat === 'function' ? await event.getChat() : event.chat;
  if (!chat || typeof client.getNotifySettings !== 'function') return false;
  const getMuteUntil = async (key, entity) => {
    const cached = cache.get(key);
    if (cached && cached.expiresAt > nowSeconds) return cached.muteUntil;
    const settings = await client.getNotifySettings(entity);
    const muteUntil = settings?.muteUntil;
    cache.set(key, { muteUntil, expiresAt: nowSeconds + 120 });
    return muteUntil;
  };

  let defaultNotifyPeer;
  let category;
  if (route.peer_type === 'user') {
    category = 'users';
    defaultNotifyPeer = new Api.InputNotifyUsers();
  } else if (route.peer_type === 'channel' && chat.broadcast) {
    category = 'broadcasts';
    defaultNotifyPeer = new Api.InputNotifyBroadcasts();
  } else {
    category = 'chats';
    defaultNotifyPeer = new Api.InputNotifyChats();
  }

  const [peerMuteUntil, defaultMuteUntil] = await Promise.all([
    getMuteUntil(`peer:${route.peer_type}:${route.peer_id}`, chat),
    getMuteUntil(`default:${category}`, defaultNotifyPeer),
  ]);
  return Number(peerMuteUntil ?? defaultMuteUntil ?? 0) > nowSeconds;
}

export async function sendTelegramNotification(event, { endpoint, apiToken, fetchImpl = fetch, client, avatarCache } = {}) {
  const payload = await formatTelegramNotification(event, { client, avatarCache });
  if (!payload) return false;
  const response = await fetchImpl(`${endpoint.replace(/\/$/, '')}/v1/send`, {
    method: 'POST',
    headers: { authorization: `Bearer ${apiToken}`, 'content-type': 'application/json' },
    body: JSON.stringify(payload),
  });
  if (!response.ok) throw new Error(`Push sender returned HTTP ${response.status}`);
  const result = await response.json();
  if (!Number.isInteger(result.sent) || !Number.isInteger(result.failed)) throw new Error('Push sender returned an invalid result');
  if (result.sent === 0) throw new Error(result.failed ? `Push sender could not deliver to any subscription (${result.failed} failed)` : 'Push sender has no saved subscriptions');
  return true;
}

async function readSession(path) {
  try {
    return (await readFile(path, 'utf8')).trim();
  } catch (error) {
    if (error.code === 'ENOENT') return '';
    throw error;
  }
}

function createClient(session, apiId, apiHash) {
  return new TelegramClient(new StringSession(session), apiId, apiHash, {
    connectionRetries: 5,
    autoReconnect: true,
  });
}

async function login() {
  const apiId = telegramApiId();
  const apiHash = requiredEnv('TELEGRAM_API_HASH');
  const sessionPath = process.env.TELEGRAM_SESSION_FILE ?? DEFAULT_SESSION_PATH;
  const rl = createInterface({ input: stdin, output: stdout });
  const client = createClient(await readSession(sessionPath), apiId, apiHash);
  try {
    await client.start({
      phoneNumber: () => rl.question('Telegram phone number (international format): '),
      phoneCode: () => rl.question('Code from Telegram: '),
      password: () => rl.question('Telegram two-step verification password: '),
      onError: error => stdout.write(`Telegram login error: ${error.message}\n`),
    });
    const session = client.session.save();
    await mkdir(dirname(sessionPath), { recursive: true, mode: 0o700 });
    await writeFile(sessionPath, `${session}\n`, { mode: 0o600 });
    await chmod(sessionPath, 0o600);
    stdout.write('Telegram session saved with owner-only permissions.\n');
  } finally {
    rl.close();
    await client.disconnect();
  }
}

async function run() {
  const apiId = telegramApiId();
  const apiHash = requiredEnv('TELEGRAM_API_HASH');
  const endpoint = requiredEnv('WEBPUSH_API_URL');
  const apiToken = requiredEnv('WEBPUSH_API_TOKEN');
  const sessionPath = process.env.TELEGRAM_SESSION_FILE ?? DEFAULT_SESSION_PATH;
  const session = await readSession(sessionPath);
  if (!session) throw new Error(`No Telegram session. Run: node telegram-bridge.mjs --login`);
  const client = createClient(session, apiId, apiHash);
  await client.connect();
  if (!await client.isUserAuthorized()) throw new Error('Telegram session expired; run the login command again');

  const notificationSettingsCache = new Map();
  const notificationAvatarCache = new Map();
  client.addEventHandler(event => {
    void (async () => {
      if (await isTelegramChatMuted(client, event, { cache: notificationSettingsCache })) return;
      await sendTelegramNotification(event, { endpoint, apiToken, client, avatarCache: notificationAvatarCache });
    })().catch(error => {
      stdout.write(`Telegram push delivery failed: ${error.message}\n`);
    });
  }, new NewMessage({ incoming: true }));

  stdout.write('Telegram message listener connected; message contents are not logged.\n');
  await client.runUntilDisconnected();
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv.includes('--login')) await login();
    else await run();
  } catch (error) {
    stdout.write(`Telegram bridge stopped: ${error.message}\n`);
    process.exitCode = 1;
  }
}
