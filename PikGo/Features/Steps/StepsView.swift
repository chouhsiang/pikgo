import SwiftUI

struct StepPatchView: View {
    @StateObject private var healthKit = HealthKitManager()

    var body: some View {
        StepsView()
            .environmentObject(healthKit)
    }
}

struct StepsView: View {
    @EnvironmentObject private var healthKit: HealthKitManager
    @State private var stepInput = ""
    @State private var selectedDate = Date()
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    @FocusState private var isStepFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 0) {
                        ForEach(
                            Array([100, 1000, 3000, 5000, 10000].enumerated()),
                            id: \.element
                        ) { index, preset in
                            let isSelected = stepInput == "\(preset)"

                            Button {
                                stepInput = "\(preset)"
                                isStepFieldFocused = false
                            } label: {
                                Text(preset, format: .number.grouping(.automatic))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(isSelected ? Color.accentColor : Color.clear)
                            }
                            .buttonStyle(.plain)

                            if index < 4 {
                                Divider()
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("快速選擇")
                }

                Section {
                    LabeledContent("步數") {
                        TextField("0", text: $stepInput)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($isStepFieldFocused)
                    }

                    DatePicker(
                        "時間",
                        selection: $selectedDate,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                } header: {
                    Text("詳細資料")
                } footer: {
                    Text("輸入步數後按「新增步數」，就會寫入「健康」App。")
                }

                Section {
                    Button {
                        Task { await syncSteps() }
                    } label: {
                        HStack {
                            Spacer()
                            if healthKit.isBusy {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(healthKit.isBusy ? "新增中…" : "新增步數")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(healthKit.isBusy || stepInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let message = healthKit.statusMessage {
                    Section {
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("步數")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        isStepFieldFocused = false
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .task {
                await prepareHealthKit()
            }
            .alert(alertTitle, isPresented: $showAlert) {
                Button("確定", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
    }

    private func prepareHealthKit() async {
        guard healthKit.isHealthDataAvailable else {
            presentAlert(
                title: "無法使用",
                message: HealthKitError.notAvailable.localizedDescription
            )
            return
        }

        do {
            try await healthKit.requestAuthorization()
        } catch {
            presentAlert(
                title: "授權失敗",
                message: error.localizedDescription
            )
        }
    }

    private func syncSteps() async {
        let trimmed = stepInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let steps = Int(trimmed), steps > 0 else {
            presentAlert(
                title: "輸入無效",
                message: HealthKitError.invalidStepCount.localizedDescription
            )
            return
        }

        do {
            try await healthKit.addSteps(steps, date: selectedDate)
            stepInput = ""
            isStepFieldFocused = false
        } catch {
            presentAlert(
                title: "同步失敗",
                message: error.localizedDescription
            )
        }
    }

    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}
