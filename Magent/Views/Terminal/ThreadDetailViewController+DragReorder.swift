import Cocoa
import MagentCore

extension ThreadDetailViewController {

    // MARK: - Drag-to-Reorder

    @objc func handleTabDrag(_ gesture: NSPanGestureRecognizer) {
        guard let draggedView = gesture.view as? TabItemView,
              let dragIndex = tabItems.firstIndex(where: { $0 === draggedView }) else { return }

        switch gesture.state {
        case .began:
            draggedView.isDragging = true
            draggedView.alphaValue = 0.85
            draggedView.layer?.zPosition = 100

        case .changed:
            let translation = gesture.translation(in: tabBarStack)
            draggedView.layer?.transform = CATransform3DMakeTranslation(translation.x, 0, 0)

            let draggedCenter = draggedView.frame.midX + translation.x

            // Only two drag groups: pinned and unpinned. All tab types mix freely.
            let isPinned = dragIndex < pinnedCount
            let rangeStart = isPinned ? 0 : pinnedCount
            let rangeEnd = isPinned ? pinnedCount : tabSlots.count

            // Check left neighbor
            if dragIndex > rangeStart {
                let leftTab = tabItems[dragIndex - 1]
                if draggedCenter < leftTab.frame.midX {
                    swapAdjacentTabs(dragIndex, dragIndex - 1, draggedView: draggedView, gesture: gesture)
                    return
                }
            }

            // Check right neighbor
            if dragIndex < rangeEnd - 1 {
                let rightTab = tabItems[dragIndex + 1]
                if draggedCenter > rightTab.frame.midX {
                    swapAdjacentTabs(dragIndex, dragIndex + 1, draggedView: draggedView, gesture: gesture)
                    return
                }
            }

        case .ended, .cancelled:
            let displacement = abs(gesture.translation(in: tabBarStack).x)
            draggedView.isDragging = false
            draggedView.alphaValue = 1.0
            draggedView.layer?.zPosition = 0
            draggedView.layer?.transform = CATransform3DIdentity
            // If the drag was negligible (click with slight jitter), treat as tap-to-select
            if displacement < 3 {
                selectTab(at: dragIndex)
            }
            persistTabOrder()
            rebindAllTabActions()

        default:
            break
        }
    }

    /// Swap two adjacent tabs in display order. Only `tabItems` and `tabSlots` are reordered;
    /// backing arrays (`terminalViews`, `webTabs`) stay in creation order.
    private func swapAdjacentTabs(_ indexA: Int, _ indexB: Int, draggedView: TabItemView, gesture: NSPanGestureRecognizer) {
        let otherView = (tabItems[indexA] === draggedView) ? tabItems[indexB] : tabItems[indexA]
        let otherOldFrame = otherView.frame

        // Swap display-order arrays only
        tabItems.swapAt(indexA, indexB)
        tabSlots.swapAt(indexA, indexB)

        // Update tracking indices
        if primaryTabIndex == indexA { primaryTabIndex = indexB }
        else if primaryTabIndex == indexB { primaryTabIndex = indexA }

        if currentTabIndex == indexA { currentTabIndex = indexB }
        else if currentTabIndex == indexB { currentTabIndex = indexA }

        // Swap positions in the stack view
        swapInStack(draggedView, otherView)

        tabBarStack.layoutSubtreeIfNeeded()

        let otherNewFrame = otherView.frame
        otherView.frame = otherOldFrame
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            otherView.animator().frame = otherNewFrame
        }

        gesture.setTranslation(.zero, in: tabBarStack)
        draggedView.layer?.transform = CATransform3DIdentity
    }

    private func swapInStack(_ viewA: NSView, _ viewB: NSView) {
        guard let idxA = tabBarStack.arrangedSubviews.firstIndex(of: viewA),
              let idxB = tabBarStack.arrangedSubviews.firstIndex(of: viewB) else { return }

        let minIdx = min(idxA, idxB)
        let maxIdx = max(idxA, idxB)
        let viewAtMin = tabBarStack.arrangedSubviews[minIdx]
        let viewAtMax = tabBarStack.arrangedSubviews[maxIdx]

        tabBarStack.removeArrangedSubview(viewAtMax)
        tabBarStack.removeArrangedSubview(viewAtMin)
        tabBarStack.insertArrangedSubview(viewAtMax, at: minIdx)
        tabBarStack.insertArrangedSubview(viewAtMin, at: maxIdx)
    }

    /// Move a tab in display order. Only `tabItems` and `tabSlots` are reordered.
    func moveTab(from source: Int, to dest: Int) {
        guard source != dest else { return }
        guard source < tabSlots.count, dest < tabSlots.count else { return }

        let item = tabItems.remove(at: source)
        tabItems.insert(item, at: dest)

        let slot = tabSlots.remove(at: source)
        tabSlots.insert(slot, at: dest)

        // Update primaryTabIndex
        if primaryTabIndex >= 0 {
            if primaryTabIndex == source {
                primaryTabIndex = dest
            } else if source < primaryTabIndex && dest >= primaryTabIndex {
                primaryTabIndex -= 1
            } else if source > primaryTabIndex && dest <= primaryTabIndex {
                primaryTabIndex += 1
            }
        }

        // Update currentTabIndex
        if currentTabIndex == source {
            currentTabIndex = dest
        } else if source < currentTabIndex && dest >= currentTabIndex {
            currentTabIndex -= 1
        } else if source > currentTabIndex && dest <= currentTabIndex {
            currentTabIndex += 1
        }
    }

    /// Persist the current display order to the thread model and disk.
    func persistTabOrder() {
        // Derive terminal session order and pinned sessions from tabSlots
        var terminalOrder: [String] = []
        var pinnedSessions: [String] = []

        for (i, slot) in tabSlots.enumerated() {
            if case .terminal(let name) = slot {
                terminalOrder.append(name)
                if i < pinnedCount {
                    pinnedSessions.append(name)
                }
            }
        }

        thread.tmuxSessionNames = terminalOrder
        threadManager.reorderTabs(for: thread.id, newOrder: terminalOrder)
        threadManager.updatePinnedTabs(for: thread.id, pinnedSessions: pinnedSessions)

        // Persist web tab order and pin state
        var newPersistedWebTabs: [PersistedWebTab] = []
        for (i, slot) in tabSlots.enumerated() {
            if case .web(let identifier) = slot {
                if var persisted = thread.persistedWebTabs.first(where: { $0.identifier == identifier }) {
                    persisted.isPinned = (i < pinnedCount)
                    newPersistedWebTabs.append(persisted)
                }
            }
        }
        thread.persistedWebTabs = newPersistedWebTabs
        threadManager.updatePersistedWebTabs(for: thread.id, webTabs: thread.persistedWebTabs)
    }
}

// MARK: - NSGestureRecognizerDelegate

extension ThreadDetailViewController: NSGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? NSPanGestureRecognizer,
              let tabView = pan.view as? TabItemView else { return true }

        let location = pan.location(in: tabView)
        let closeBounds = tabView.closeButton.convert(tabView.closeButton.bounds, to: tabView)
        if closeBounds.contains(location) { return false }

        return true
    }
}
