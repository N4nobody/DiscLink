import SwiftUI
import UDFKit

extension DiscImportConflict {
    enum Kind: Hashable { case files, folders, incomingFile, incomingFolder }

    var kind: Kind {
        switch (incomingIsDirectory, existingIsDirectory) {
        case (false, false): return .files
        case (true, true): return .folders
        case (false, true): return .incomingFile
        case (true, false): return .incomingFolder
        }
    }
}

struct ImportConflictView: View {
    @EnvironmentObject private var model: AppModel
    let conflict: DiscImportConflict

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("“\(conflict.source.lastPathComponent)”重名", "Name conflict for “\(conflict.source.lastPathComponent)”"))
                .font(.headline).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("来自 Mac：\((conflict.source.path as NSString).abbreviatingWithTildeInPath)",
                       "From Mac: \((conflict.source.path as NSString).abbreviatingWithTildeInPath)"))
                Text(L("光盘位置：/\(conflict.path)", "On disc: /\(conflict.path)"))
            }
            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text(explanation)
            Text(L("保留两者时，新项目将命名为“\(conflict.copyName)”。",
                   "Keep Both will name the incoming item “\(conflict.copyName)”."))
            Toggle(L("对本批后续同类重名使用相同选择", "Use this choice for remaining conflicts of this type"),
                   isOn: $model.applyChoiceToRemainder)
                .toggleStyle(.checkbox)
            HStack {
                Button(L("取消整批", "Cancel Import")) { model.answerImportConflict(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("跳过", "Skip")) { model.answerImportConflict(.skip) }
                if conflict.kind == .files {
                    Button(L("替换", "Replace")) { model.answerImportConflict(.replace) }
                } else if conflict.kind == .folders {
                    Button(L("合并", "Merge")) { model.answerImportConflict(.merge) }
                }
                Button(L("保留两者", "Keep Both")) { model.answerImportConflict(.keepBoth) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 480).interactiveDismissDisabled()
    }

    private var explanation: String {
        switch conflict.kind {
        case .files:
            if conflict.existingIsPlanned {
                return L("本批中另一个文件也将使用这个名字。选择替换会采用当前文件。", "Another file in this import has the same name. Replace will use the current file.")
            }
            if model.info?.isWriteOnce == true {
                return L("光盘上已有同名文件。替换后显示新版本，旧版本占用的空间仍会保留。", "A file with this name is already on the disc. Replace will show the new version. The old version will still occupy space.")
            }
            return L("光盘上已有同名文件。替换会用当前文件覆盖已有文件。", "A file with this name is already on the disc. Replace will overwrite it with the incoming file.")
        case .folders:
            return L("合并会保留两个文件夹的内容，里面的同名文件可以单独处理。", "Merge will combine the folders. You can choose what to do with matching files inside.")
        case .incomingFile:
            return L("这个名字已被文件夹使用。你可以给拖入的文件另取名称，或跳过它。", "A folder uses this name. You can keep the incoming file under a new name or skip it.")
        case .incomingFolder:
            return L("这个名字已被文件使用。你可以给新文件夹另取名称，或跳过它。", "A file uses this name. You can keep the incoming folder under a new name or skip it.")
        }
    }
}
