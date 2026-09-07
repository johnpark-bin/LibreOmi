/// Memories page - displays extracted facts from conversations
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../controllers/library_controller.dart';
import '../l10n/l10n.dart';

class MemoriesPage extends StatelessWidget {
  const MemoriesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.memories_title),
        actions: [
          Consumer<LibraryController>(
            builder: (context, provider, _) => provider.memories.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: provider.loadMemories,
                    tooltip: l10n.memories_refreshTooltip,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
      body: Consumer<LibraryController>(
        builder: (context, provider, _) {
          if (provider.memories.isEmpty) {
            return _buildEmptyState(theme, l10n);
          }
          return _buildMemoriesList(context, provider, theme, l10n);
        },
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, AppLocalizations l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF6C5CE7).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.psychology_outlined,
                size: 48,
                color: Color(0xFF6C5CE7),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              l10n.memories_emptyTitle,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.memories_emptySubtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.memories_emptyHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withOpacity(0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMemoriesList(BuildContext context, LibraryController provider, ThemeData theme, AppLocalizations l10n) {
    final memories = provider.memories;
    
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: memories.length,
      itemBuilder: (context, index) {
        final memory = memories[index];
        return Dismissible(
          key: Key(memory.id),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            color: Colors.red.withOpacity(0.2),
            child: const Icon(Icons.delete, color: Colors.red),
          ),
          onDismissed: (_) => provider.deleteMemory(memory.id),
          child: Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6C5CE7).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.lightbulb_outline,
                      color: Color(0xFF6C5CE7),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          memory.content,
                          style: const TextStyle(fontSize: 15),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _formatDate(l10n, memory.createdAt),
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface.withOpacity(0.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.edit_outlined,
                      size: 20,
                      color: theme.colorScheme.onSurface.withOpacity(0.3),
                    ),
                    onPressed: () => _showEditDialog(context, provider, memory.id, memory.content),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.delete_outline,
                      size: 20,
                      color: theme.colorScheme.onSurface.withOpacity(0.3),
                    ),
                    onPressed: () => _confirmDelete(context, provider, memory.id),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _formatDate(AppLocalizations l10n, DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inMinutes < 60) {
      return l10n.memories_ageMinutes(diff.inMinutes);
    } else if (diff.inHours < 24) {
      return l10n.memories_ageHours(diff.inHours);
    } else if (diff.inDays < 7) {
      return l10n.memories_ageDays(diff.inDays);
    } else {
      // `intl` rather than a hardcoded US order: Korean writes the date
      // year-first. Symbols for both locales are loaded by
      // `GlobalMaterialLocalizations`.
      return DateFormat.yMd(l10n.localeName).format(date);
    }
  }

  void _confirmDelete(BuildContext context, LibraryController provider, String memoryId) {
    final l10n = L10n.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.memories_deleteConfirmTitle),
        content: Text(l10n.memories_deleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.common_cancelButton),
          ),
          TextButton(
            onPressed: () {
              provider.deleteMemory(memoryId);
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l10n.memories_deleteButton),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(BuildContext context, LibraryController provider, String memoryId, String currentContent) {
    final controller = TextEditingController(text: currentContent);
    final l10n = L10n.of(context);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.memories_editTitle),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: l10n.memories_editHint,
            border: const OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.common_cancelButton),
          ),
          TextButton(
            onPressed: () {
              final newContent = controller.text.trim();
              if (newContent.isNotEmpty && newContent != currentContent) {
                provider.updateMemory(memoryId, newContent);
              }
              Navigator.pop(context);
            },
            child: Text(l10n.memories_saveButton),
          ),
        ],
      ),
    );
  }
}
