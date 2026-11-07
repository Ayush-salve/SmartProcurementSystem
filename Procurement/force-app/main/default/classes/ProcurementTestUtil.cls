@IsTest
public class ProcurementTestUtil {

    // Makes the running user a member of the named queues so the user can act as an approver in tests.
    public static void addCurrentUserToQueues(List<String> queueDeveloperNames) {
        List<Group> queues = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName IN :queueDeveloperNames];
        List<GroupMember> members = new List<GroupMember>();
        for (Group q : queues) {
            members.add(new GroupMember(GroupId = q.Id, UserOrGroupId = UserInfo.getUserId()));
        }
        // Group membership is a setup object, so it must be written in its own user context.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert members;
        }
    }

    public static ProcessInstanceWorkitem openWorkitem(Id recordId) {
        List<ProcessInstanceWorkitem> items = [
            SELECT Id, ProcessInstance.ProcessDefinition.DeveloperName
            FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :recordId
        ];
        return items.isEmpty() ? null : items[0];
    }

    public static void decide(Id recordId, String action, String comments) {
        ProcessInstanceWorkitem item = openWorkitem(recordId);
        System.assertNotEquals(null, item, 'Expected an open approval work item');
        Approval.ProcessWorkitemRequest request = new Approval.ProcessWorkitemRequest();
        request.setWorkitemId(item.Id);
        request.setAction(action);
        request.setComments(comments);
        Approval.ProcessResult result = Approval.process(request);
        System.assert(result.isSuccess());
    }

    public static String processNameFor(Id recordId) {
        List<ProcessInstance> instances = [
            SELECT ProcessDefinition.DeveloperName FROM ProcessInstance
            WHERE TargetObjectId = :recordId ORDER BY CreatedDate DESC LIMIT 1
        ];
        return instances.isEmpty() ? null : instances[0].ProcessDefinition.DeveloperName;
    }
}
