func topLevelAsyncLetValue(_ value: Int) async -> Int {
    await Task.yield()
    return value
}

async let topLevelLeft = topLevelAsyncLetValue(20)
async let topLevelRight = topLevelAsyncLetValue(22)
let topLevelAsyncLetResult = await topLevelLeft + topLevelRight
print(String(topLevelAsyncLetResult))
String(topLevelAsyncLetResult)
