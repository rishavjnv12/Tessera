import SwiftUI

/// Torrent list on top, details below.
///
/// A thin bar sits on top of the details: drag it to resize (the grip in the middle hints at
/// that), double-click it or use the chevron to hide or show the details. Hidden details leave
/// just the bar, so they can be brought back from here.
///
/// Built by hand instead of `VSplitView` so the height is remembered across launches.
/// No GeometryReader drives the layout: one here (and one in the details) stopped receiving new
/// widths after the window or sidebar changed size, which left the details laid out for the old,
/// wider width and spilling under the sidebar. Plain flexible frames always follow the window, and
/// both halves accept any width so nothing inside can force the window wider.
struct DetailsSplit<Top: View, Bottom: View>: View {
    /// Whether to show the bar and details at all (false when there is nothing to list).
    var hasPane: Bool
    @Binding var isExpanded: Bool
    /// Remembered height of the details, in points.
    @Binding var bottomHeight: Double
    /// Shown in the bar while the details are hidden.
    var title: String
    var minTopHeight: CGFloat = 140
    var minBottomHeight: CGFloat = 200
    @ViewBuilder var top: Top
    @ViewBuilder var bottom: Bottom

    /// Height while dragging; written to `bottomHeight` when the drag ends.
    @State private var dragHeight: Double?
    @State private var dragStartHeight: Double = 0
    /// Total height available, recorded only to keep the details within bounds.
    @State private var totalHeight: CGFloat = 0

    private static var barHeight: CGFloat { 24 }

    private var maxBottomHeight: Double {
        guard totalHeight > 0 else { return .infinity }
        return max(Double(minBottomHeight), Double(totalHeight - minTopHeight - Self.barHeight))
    }

    private var currentHeight: Double {
        clamp(dragHeight ?? bottomHeight)
    }

    var body: some View {
        // List above, details below, side by side in one stack: the list never runs under the details,
        // so there is nothing for the macOS 26 scroll-edge effect to blur (it doubled the last rows when
        // the details were a bottom inset of the list).
        VStack(spacing: 0) {
            top
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            if hasPane {
                bar
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.barHeight)
                if isExpanded {
                    bottom
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                        .frame(height: currentHeight)
                        .clipped()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { totalHeight = $0 }
    }

    // MARK: Bar

    private var bar: some View {
        ZStack {
            // Collapsed: say what is selected, so the bar isn't a mystery strip.
            if !isExpanded {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .padding(.trailing, 40)
            }
            grip
            HStack {
                Spacer()
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .pointerStyle(.default)
                .help(isExpanded ? "Hide Details (⌥⌘I)" : "Show Details (⌥⌘I)")
                .accessibilityLabel(isExpanded ? "Hide Details" : "Show Details")
                .padding(.trailing, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        .pointerStyle(isExpanded ? .rowResize : .default)
        .onTapGesture(count: 2) { isExpanded.toggle() }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    guard isExpanded else { return }
                    if dragHeight == nil { dragStartHeight = currentHeight }
                    dragHeight = clamp(dragStartHeight - value.translation.height)
                }
                .onEnded { _ in
                    if let dragHeight { bottomHeight = dragHeight }
                    dragHeight = nil
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details divider")
        .accessibilityHint(isExpanded ? "Drag up or down to resize the details" : "")
    }

    /// The grabber: a short rounded bar, like the one on sheets, that reads as "drag me".
    private var grip: some View {
        Capsule()
            .fill(.tertiary)
            .frame(width: 36, height: 5)
            .opacity(isExpanded ? 1 : 0.5)
            .accessibilityHidden(true)
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, Double(minBottomHeight)), maxBottomHeight)
    }
}
