import EveeCore
import SwiftUI

struct EveeSettingsCategoryRail: View {
    @Binding var selection: EveeSettingsCategory

    @FocusState private var focusedCategory: EveeSettingsCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: EveeSpacing.small) {
            Text("Settings")
                .font(EveeTypography.sectionTitle)
                .foregroundStyle(EveeVisual.secondaryText)
                .padding(.horizontal, EveeSpacing.medium)
                .padding(.top, EveeSpacing.large)

            VStack(spacing: EveeSpacing.xSmall) {
                ForEach(EveeSettingsCategory.allCases) { category in
                    categoryButton(category)
                }
            }
            .onMoveCommand(perform: moveSelection)

            Spacer(minLength: EveeSpacing.medium)
        }
        .padding(.horizontal, EveeSpacing.small)
        .eveeMaterial(.rail)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings categories")
    }

    private func categoryButton(_ category: EveeSettingsCategory) -> some View {
        let isSelected = selection == category
        let isFocused = focusedCategory == category

        return Button {
            selection = category
        } label: {
            HStack(spacing: EveeSpacing.small) {
                Image(systemName: category.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? EveeVisual.accent : EveeVisual.secondaryText)
                    .frame(width: 19)
                    .accessibilityHidden(true)
                Text(category.title)
                    .font(EveeTypography.body.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(EveeVisual.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, EveeSpacing.small)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .background(isSelected ? EveeVisual.surface : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius, style: .continuous)
                    .stroke(isFocused ? EveeVisual.accent : Color.clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .focused($focusedCategory, equals: category)
        .accessibilityLabel(category.title)
        .accessibilityHint("Shows \(category.title) settings.")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("Show \(category.title) settings")
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let offset: Int
        switch direction {
        case .up: offset = -1
        case .down: offset = 1
        default: return
        }

        let categories = EveeSettingsCategory.allCases
        guard let currentIndex = categories.firstIndex(of: focusedCategory ?? selection) else { return }
        let destinationIndex = min(max(0, currentIndex + offset), categories.count - 1)
        let destination = categories[destinationIndex]
        selection = destination
        focusedCategory = destination
    }
}
