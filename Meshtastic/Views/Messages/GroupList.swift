//
//  GroupList.swift
//  Meshtastic
//
//  Group message conversation list view.
//

import SwiftUI
import OSLog

struct GroupList: View {

	@EnvironmentObject var accessoryManager: AccessoryManager
	@ObservedObject private var groupService = GroupMessageService.shared
	@Binding var selectedGroupId: UInt32?
	@State private var showingCreateGroup = false
	@State private var showingJoinGroup = false

	private var sortedGroups: [GroupMessageService.GroupInfo] {
		groupService.joinedGroups.values.sorted { a, b in
			let aUnread = groupService.unreadCounts[a.groupId] ?? 0
			let bUnread = groupService.unreadCounts[b.groupId] ?? 0
			// Unread groups first
			if aUnread > 0 && bUnread == 0 { return true }
			if aUnread == 0 && bUnread > 0 { return false }
			// Then by last activity descending
			let aLast = groupService.groupMessages[a.groupId]?.last?.timestamp ?? a.createdAt
			let bLast = groupService.groupMessages[b.groupId]?.last?.timestamp ?? b.createdAt
			return aLast > bLast
		}
	}

	var body: some View {
		VStack(spacing: 0) {
			if sortedGroups.isEmpty {
				ContentUnavailableView {
					Label("No Groups", systemImage: "person.3")
				} description: {
					Text("Create or join a group to start messaging with acknowledged delivery.")
				} actions: {
					HStack(spacing: 16) {
						Button {
							showingCreateGroup = true
						} label: {
							Label("Create Group", systemImage: "plus.circle.fill")
						}
						.buttonStyle(.borderedProminent)

						Button {
							showingJoinGroup = true
						} label: {
							Label("Join Group", systemImage: "person.badge.plus")
						}
						.buttonStyle(.bordered)
					}
				}
			} else {
				List(selection: $selectedGroupId) {
					// Action buttons at top
					Section {
						HStack(spacing: 12) {
							Button {
								showingCreateGroup = true
							} label: {
								Label("Create", systemImage: "plus.circle.fill")
									.frame(maxWidth: .infinity)
							}
							.buttonStyle(.bordered)
							.tint(.accentColor)

							Button {
								showingJoinGroup = true
							} label: {
								Label("Join", systemImage: "person.badge.plus")
									.frame(maxWidth: .infinity)
							}
							.buttonStyle(.bordered)
							.tint(.accentColor)
						}
						.listRowBackground(Color.clear)
						.listRowSeparator(.hidden)
					}

					// Group list
					Section {
						ForEach(sortedGroups) { group in
							NavigationLink(value: group.groupId) {
								makeGroupRow(group: group)
							}
							.alignmentGuide(.listRowSeparatorLeading) {
								$0[.leading]
							}
							.frame(height: 62)
							.contextMenu {
								Button(role: .destructive) {
									leaveAndRemoveGroup(group)
								} label: {
									Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
								}
							}
						}
					}
				}
				.listStyle(.plain)
			}
		}
		.navigationTitle("Group Messages")
		.toolbar {
			ToolbarItem(placement: .navigationBarTrailing) {
				Menu {
					Button {
						showingCreateGroup = true
					} label: {
						Label("Create Group", systemImage: "plus.circle")
					}
					Button {
						showingJoinGroup = true
					} label: {
						Label("Join Group", systemImage: "person.badge.plus")
					}
				} label: {
					Image(systemName: "plus.circle")
				}
			}
		}
		.sheet(isPresented: $showingCreateGroup) {
			CreateGroupSheet()
		}
		.sheet(isPresented: $showingJoinGroup) {
			JoinGroupSheet()
		}
	}

	private func leaveAndRemoveGroup(_ group: GroupMessageService.GroupInfo) {
		Task {
			do {
				try await groupService.leaveGroup(
					groupId: group.groupId,
					accessoryManager: accessoryManager
				)
			} catch {
				// Fallback: remove locally even if send fails
				groupService.groupMessages.removeValue(forKey: group.groupId)
				groupService.joinedGroups.removeValue(forKey: group.groupId)
				groupService.unreadCounts.removeValue(forKey: group.groupId)
				groupService.saveState()
			}
			if selectedGroupId == group.groupId {
				selectedGroupId = nil
			}
		}
	}

	@ViewBuilder
	private func makeGroupRow(group: GroupMessageService.GroupInfo) -> some View {
		let messages = groupService.groupMessages[group.groupId] ?? []
		let lastMessage = messages.last
		let hasMessages = lastMessage != nil
		let unread = groupService.unreadCounts[group.groupId] ?? 0

		HStack(alignment: .center) {
			ZStack(alignment: .topTrailing) {
				Image(systemName: "person.3.fill")
					.resizable()
					.symbolRenderingMode(.hierarchical)
					.foregroundColor(.accentColor)
					.aspectRatio(contentMode: .fit)
					.frame(width: 36, height: 36)

				if unread > 0 {
					Text("\(unread)")
						.font(.system(size: 10, weight: .bold))
						.foregroundColor(.white)
						.padding(3)
						.background(Color.red)
						.clipShape(Circle())
						.offset(x: 4, y: -4)
				}
			}
			.padding(.trailing, 4)

			VStack(alignment: .leading) {
				HStack {
					Text(group.name)
						.font(.headline)
						.fontWeight(unread > 0 ? .bold : .regular)
					Spacer()
					if hasMessages {
						Text(lastMessage!.timestamp, style: .time)
							.font(.footnote)
							.foregroundColor(unread > 0 ? .accentColor : .secondary)
					}
				}
				HStack {
					if hasMessages {
						if lastMessage!.type == .groupText {
							Text(lastMessage!.text)
								.font(.footnote)
								.foregroundColor(.secondary)
								.fontWeight(unread > 0 ? .semibold : .regular)
								.lineLimit(1)
						} else {
							Text(lastMessage!.text)
								.font(.footnote)
								.foregroundColor(.secondary)
								.italic()
								.lineLimit(1)
						}
					} else {
						Text("\(group.members.count) members")
							.font(.footnote)
							.foregroundColor(.secondary)
					}
				}
			}
		}
	}
}
