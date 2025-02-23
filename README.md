# Bulletins

A SourceMod plugin that provides a database-driven bulletin system for sending announcements to players. Supports both global messages and optional subscriptions.

## Features

- Global bulletins that are shown to all players
- Optional bulletins that players can subscribe/unsubscribe from
- Messages are tracked per-player to avoid repeats
- Panel-based interface with navigation options
- Automatic database setup

## Commands

- `sm_bulletin <type> <message>` - Add a new bulletin (Admin only)
  - Types: `global`, `optional`
- `sm_subscribe` - Subscribe to optional bulletins
- `sm_unsubscribe` - Unsubscribe from optional bulletins

## Installation

1. Upload files to your `addons/sourcemod` directory
2. Add a "bulletins" entry to your `databases.cfg`:
```
"bulletins"
{
    "driver"     "mysql"
    "host"       "localhost"
    "database"   "your_database"
    "user"       "your_username"
    "pass"       "your_password"
}
```
3. Reload the plugin or restart your server

## Requirements

- SourceMod 1.11 or higher
- MySQL database
- [Updater](https://github.com/Teamkiller324/Updater) (optional)