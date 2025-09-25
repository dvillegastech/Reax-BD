# ReaxDB - Open Source Database for Dart & Flutter

[![pub package](https://img.shields.io/pub/v/reaxdb_dart.svg)](https://pub.dev/packages/reaxdb_dart)
[![GitHub stars](https://img.shields.io/github/stars/dvillegastech/Reax-BD.svg)](https://github.com/dvillegastech/Reax-BD/stargazers)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Open Source Love](https://badges.frapsoft.com/os/v1/open-source.svg?v=103)](https://github.com/ellerbrock/open-source-badges/)
[![Dart](https://img.shields.io/badge/Dart-%E2%9D%A4-blue)](https://dart.dev)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/dvillegastech/Reax-BD/pulls)

**🌟 100% Open Source | MIT Licensed | Community-Driven**

**The simplest way to store data in Dart & Flutter.** Start with just 3 lines of code, scale to millions of records.

> 🆕 **Version 1.4.0**: Introducing Simple API - Zero configuration, 3 lines to start! [See changelog](CHANGELOG.md)

## 🌟 Open Source Project

ReaxDB is a **free and open source** project licensed under the MIT License. This means you can:
- ✅ Use it in personal and commercial projects
- ✅ Modify and distribute the source code
- ✅ Contribute to make it better for everyone
- ✅ Fork it and create your own version

We believe in the power of open source to create better software together! [Join us on GitHub →](https://github.com/dvillegastech/Reax-BD)

```dart
// That's it! You're ready to go
final db = await ReaxDB.simple('myapp');
await db.put('user', {'name': 'John', 'age': 30});
final user = await db.get('user');
```

## Why ReaxDB?

✅ **Dead Simple** - Start with 3 lines, no configuration needed  
✅ **Blazing Fast** - 21,000+ writes/second, instant cache reads  
✅ **Scale When Ready** - From simple key-value to advanced queries  
✅ **Pure Dart** - Works everywhere: iOS, Android, Web, Desktop, Server  
✅ **Production Ready** - ACID transactions, encryption, real-time sync  

## Installation

```yaml
dependencies:
  reaxdb_dart: ^1.4.0
```

## Quick Start

### 1. Basic Usage (90% of use cases)

```dart
import 'package:reaxdb_dart/reaxdb_dart.dart';

// Open database
final db = await ReaxDB.simple('myapp');

// Store any JSON data
await db.put('user:1', {
  'name': 'Alice',
  'email': 'alice@example.com',
  'age': 25
});

// Get data
final user = await db.get('user:1');
print(user['name']); // Alice

// Query with patterns
final users = await db.getAll('user:*');
users.forEach((key, value) {
  print('$key: ${value['name']}');
});

// Delete data
await db.delete('user:1');

// Close when done
await db.close();
```

### 2. Real-time Updates

```dart
// Listen to changes
db.watch('user:*').listen((event) {
  print('User ${event.key} changed');
});

// Make changes - listeners are notified automatically
await db.put('user:2', {'name': 'Bob'});
```

### 3. Batch Operations (faster for multiple items)

```dart
// Store multiple items at once
await db.putAll({
  'user:1': {'name': 'Alice'},
  'user:2': {'name': 'Bob'},
  'user:3': {'name': 'Charlie'},
});

// Delete multiple items
await db.deleteAll(['user:1', 'user:2']);
```

## When to Use ReaxDB

### Perfect for:
- 📱 **Mobile apps** needing offline-first storage
- 🚀 **Startups** wanting to move fast without database complexity
- 📊 **Apps with 100-1M records** that need speed
- 🔄 **Real-time features** like live updates, syncing
- 🛡️ **Secure apps** needing built-in encryption

### ReaxDB vs Others:

| Feature | ReaxDB | Hive | SQLite | Isar |
|---------|--------|------|--------|------|
| Setup complexity | ⭐ Simple | ⭐ Simple | ⭐⭐⭐ Complex | ⭐⭐ Medium |
| Performance | ⚡ 21k/sec | ⚡ Fast | 🐢 Slower | ⚡ Fast |
| Pure Dart | ✅ Yes | ✅ Yes | ❌ No | ❌ No |
| Real-time | ✅ Built-in | ❌ No | ❌ No | ✅ Yes |
| Encryption | ✅ Built-in | ✅ Yes | ⚠️ Extension | ✅ Yes |
| Advanced queries | ✅ Yes | ❌ Limited | ✅ SQL | ✅ Yes |
| Active development | ✅ Yes | ⚠️ Deprecated | ✅ Yes | ✅ Yes |

## Need More Power?

ReaxDB grows with your app. When you need advanced features, they're one line away:

```dart
// Need transactions? ✅
await db.advanced.transaction((txn) async {
  // Your atomic operations here
});

// Need indexes for complex queries? ✅
await db.advanced.createIndex('users', 'age');
final youngUsers = await db.advanced.collection('users')
    .whereBetween('age', 18, 25)
    .find();

// Need encryption? ✅
final secureDb = await ReaxDB.simple('myapp', encrypted: true);
```

📚 **[See Advanced Documentation](ADVANCED.md)** for transactions, indexes, aggregations, and more.

## Examples

### Todo App
```dart
// Store todos
await db.put('todo:1', {
  'title': 'Buy milk',
  'done': false,
  'created': DateTime.now().toIso8601String()
});

// Get all todos
final todos = await db.getAll('todo:*');

// Mark as done
final todo = await db.get('todo:1');
todo['done'] = true;
await db.put('todo:1', todo);
```

### User Settings
```dart
// Save settings
await db.put('settings', {
  'theme': 'dark',
  'notifications': true,
  'language': 'en'
});

// Read settings
final settings = await db.get('settings');
final isDark = settings['theme'] == 'dark';
```

### Shopping Cart
```dart
// Add to cart
await db.put('cart:product-123', {
  'name': 'Flutter Book',
  'price': 29.99,
  'quantity': 2
});

// Get cart total
final items = await db.getAll('cart:*');
double total = 0;
items.forEach((_, item) {
  total += item['price'] * item['quantity'];
});
```

## Performance

- **21,000+** writes per second
- **333,000+** reads per second from cache
- **Handles millions** of records efficiently
- **10x faster** than SQLite for key-value operations

## Resources

### Documentation
- 📖 [Advanced Documentation](ADVANCED.md) - Transactions, indexes, performance tuning
- 📊 [Performance Benchmarks](BENCHMARKS.md) - Detailed comparisons with other databases
- 🚀 [Migration Guide](MIGRATION.md) - Moving from Hive/Isar to ReaxDB

### Examples
- 💡 [Simple Example](examples/simple_example.dart) - Quick start guide
- ✅ [Todo App](examples/todo_app.dart) - Full-featured todo application
- 💬 [Chat App](examples/chat_app.dart) - Real-time chat with encryption
- 🎮 [Flutter Demo](example/lib/simple_demo.dart) - Interactive Flutter demo

## Open Source & Contributing

ReaxDB is **100% open source** and we love contributions from the community! Whether you're fixing bugs, adding features, improving documentation, or sharing ideas - all contributions are welcome.

### How to Contribute

1. 🍴 **Fork the repository** - [github.com/dvillegastech/Reax-BD](https://github.com/dvillegastech/Reax-BD)
2. 🔧 **Create your feature branch** - `git checkout -b feature/amazing-feature`
3. 💻 **Make your changes** - Write code, tests, and documentation
4. ✅ **Run tests** - `flutter test`
5. 📤 **Submit a Pull Request** - We'll review it ASAP!

### Ways to Contribute

- **🐛 Report bugs** - Found an issue? [Let us know!](https://github.com/dvillegastech/Reax-BD/issues)
- **💡 Suggest features** - Have an idea? [Open a discussion!](https://github.com/dvillegastech/Reax-BD/discussions)
- **📝 Improve documentation** - Help others understand ReaxDB better
- **🌍 Translations** - Help make ReaxDB accessible globally
- **⭐ Star the repo** - Show your support and help others discover ReaxDB
- **📢 Share** - Blog about your experience, tweet, or tell your friends!

### Community

Join our growing open source community:

- 💬 [GitHub Discussions](https://github.com/dvillegastech/Reax-BD/discussions) - Ask questions, share ideas
- 🐛 [Issue Tracker](https://github.com/dvillegastech/Reax-BD/issues) - Report bugs, request features
- 📧 [Email](mailto:contact@dvillegas.tech) - For security issues or private concerns

### Contributors

A huge thank you to all our contributors! 🙏

<!-- ALL-CONTRIBUTORS-LIST:START -->
<!-- ALL-CONTRIBUTORS-LIST:END -->

Want to see your name here? [Start contributing today!](https://github.com/dvillegastech/Reax-BD/blob/main/CONTRIBUTING.md)

## Support

- 🐛 [Report Issues](https://github.com/dvillegastech/Reax-BD/issues)
- ⭐ [Star on GitHub](https://github.com/dvillegastech/Reax-BD)
- ☕ [Support Development](https://buymeacoffee.com/dvillegas)

## License

This project is **open source** and available under the **MIT License**.

MIT License - see [LICENSE](LICENSE) file for details.

---

**Ready to build something amazing?** Start with `ReaxDB.simple()` and scale when you need to! 🚀