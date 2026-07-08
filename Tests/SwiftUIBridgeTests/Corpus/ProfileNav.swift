struct Friend {
    var name = ""
    var role = ""
    var icon = "person"
}

struct FriendDetail: View {
    var friend = Friend()

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: friend.icon)
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text(friend.name)
                .font(.title2)
                .bold()
            Text(friend.role)
                .foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle(friend.name)
    }
}

struct FriendRow: View {
    var friend = Friend()

    var body: some View {
        HStack {
            Image(systemName: friend.icon)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.name)
                Text(friend.role)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct ContentView: View {
    static let friends = [
        Friend(name: "Ada Lovelace", role: "Analyst", icon: "function"),
        Friend(name: "Grace Hopper", role: "Rear admiral", icon: "laptopcomputer"),
        Friend(name: "Katherine Johnson", role: "Navigator", icon: "moon.stars"),
    ]

    var body: some View {
        NavigationStack {
            List(ContentView.friends, id: \.name) { friend in
                NavigationLink(destination: FriendDetail(friend: friend)) {
                    FriendRow(friend: friend)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("People")
        }
        .frame(maxWidth: 420, maxHeight: 400)
    }
}
