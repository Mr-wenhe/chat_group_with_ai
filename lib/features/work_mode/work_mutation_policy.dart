import 'work_change_plan.dart';

export 'work_change_plan.dart';

/// Naming used by the Stage 02 design; the implementation remains pure and
/// does not execute mutations.
class WorkMutationPolicy {
  const WorkMutationPolicy._();

  static WorkChangePolicyResult evaluate({
    required WorkChangePlan plan,
    required WorkChangePolicySettings settings,
    WorkApprovalScope? scope,
  }) {
    return WorkChangePolicy.evaluate(
      plan: plan,
      settings: settings,
      scope: scope,
    );
  }
}

typedef WorkMutationPolicySettings = WorkChangePolicySettings;
typedef WorkMutationPolicyResult = WorkChangePolicyResult;
typedef WorkMutationApprovalRequirement = WorkChangeApprovalRequirement;
