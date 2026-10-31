import { startApp } from './app';
import { connection } from './core/connection';
import { startTray } from './tray';

startApp(document.getElementById('app')!, connection);
startTray(connection);
