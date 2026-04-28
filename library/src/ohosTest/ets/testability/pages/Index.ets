@Entry
@Component
struct Index {
  @State message: string = 'Countly SDK · test runner';

  build() {
    Row() {
      Column() {
        Text(this.message)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
        Text('Tests run through hypium; see DevEco \"Run > Test\" output.')
          .fontSize(14)
          .margin({ top: 12 })
      }
      .width('100%')
    }
    .height('100%')
  }
}
