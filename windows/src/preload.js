const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('pare', {
  init: () => ipcRenderer.invoke('init'),
  setup: () => ipcRenderer.invoke('setup'),
  settings: (change) => ipcRenderer.invoke('settings', change),
  start: (text) => ipcRenderer.invoke('start', text),
  cancel: () => ipcRenderer.invoke('cancel'),
  unlock: (id, creds) => ipcRenderer.invoke('unlock', id, creds),
  find: (id) => ipcRenderer.invoke('find', id),
  chooseFolder: () => ipcRenderer.invoke('chooseFolder'),
  openFolder: () => ipcRenderer.invoke('openFolder'),
  checkUpdate: () => ipcRenderer.invoke('checkUpdate'),
  installUpdate: () => ipcRenderer.invoke('installUpdate'),
  on: (channel, fn) => ipcRenderer.on(channel, (_e, data) => fn(data)),
});
