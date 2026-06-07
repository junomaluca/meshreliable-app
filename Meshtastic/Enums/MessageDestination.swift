/// Helper abstraction for sharing functionality between channel, direct, and group messaging.
enum MessageDestination {
	case user(UserEntity)
	case channel(ChannelEntity)
	case group(groupId: UInt32, channelIndex: Int32)

	var userNum: Int64 {
		switch self {
		case let .user(user): return user.num
		case .channel: return 0
		case .group: return 0
		}
	}

	var channelNum: Int32 {
		switch self {
		case .user: return 0
		case let .channel(channel): return channel.index
		case let .group(_, channelIndex): return channelIndex
		}
	}
}
