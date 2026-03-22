# Risk Assessment

NARA is live and experimental.

The protocol is stronger when its risks are explicit.

## Current Structural Risks

### Thin Float

The liquid float is small relative to total supply.

That is part of what makes NARA interesting, but it also means price discovery can be fragile early.

### Early Concentration

Large early lockers can accumulate significant relative weight before broader participation arrives.

This is not necessarily a bug, but it is a real economic dynamic.

### Activation Complexity

New users do not earn immediately after locking.

If activation delay and warmup are not made visible, users can misread the experience and lose confidence.

### Bond Timing Risk

The bond stack is deployed, but opening it too early could damage market structure if liquidity is still too thin.

### Operational Dependency

The engine requires epoch advancement.

If operational support fails and no one advances epochs, user experience degrades even though the contracts remain live.

## Product-Level Risks

### Overfitting To One Surface

If the community mistakes the board for the full protocol, NARA can look smaller than it really is.

### Messaging Risk

If NARA is pitched as easy yield or fast money, it will attract the wrong expectations.

### Visibility Risk

If users cannot see activation status, warmup, backlog, and reward state clearly, confusion will outweigh protocol quality.

## Risk Posture

The right strategy is not to hide these risks.

The right strategy is to:

- keep state visible
- keep docs current
- keep bonds closed until conditions justify opening
- improve surfaces without changing the core thesis every time a campaign underperforms
