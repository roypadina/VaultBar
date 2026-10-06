/// Whether a copy started outside launchd may hand off to the login agent now (it exits to let launchd start the
/// supervised copy). Only when nothing is in progress, so no action is cut off: a link's unlock prompt, an
/// attach or detach still running, a busy vault waiting for its forced lock, a pause, or an open window, menu or alert.
public func canHandOff(isAgent: Bool, handOffDisabled: Bool, launchAtLogin: Bool, agentEnabled: Bool,
                       prompting: Bool, inFlight: Int, pendingForce: Int, paused: Bool, uiOpen: Bool) -> Bool {
    !isAgent && !handOffDisabled && launchAtLogin && agentEnabled
        && !prompting && inFlight == 0 && pendingForce == 0 && !paused && !uiOpen
}
