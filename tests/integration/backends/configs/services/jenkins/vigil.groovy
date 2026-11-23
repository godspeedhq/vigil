// Copyright (c) Bankole Ogundero and the Vigil contributors
// SPDX-License-Identifier: Apache-2.0
//
// Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
// implied. Run it at your own risk: review it first, and test it before you
// rely on it. In no event shall the authors or copyright holders be liable
// for any claim, damages or other liability arising from its use. See the
// LICENSE file for the full terms.
//
// vigil.groovy - a Jenkins in trouble on purpose, for the jenkins pack's
// tests (scripts/run-jenkins.sh): its users and their API tokens (written to
// $JENKINS_HOME/vigil, readable by Jenkins' account alone, and read from
// there by the run with docker exec), two agents that never connect (one taken offline by
// hand), and jobs: passing, failing (one in a folder), unstable, disabled,
// never built, one that runs far past its estimate, and one waiting for a
// label no node has. Run once, at Jenkins' first start.
import jenkins.model.*
import hudson.model.*
import hudson.security.*
import hudson.slaves.*
import hudson.tasks.Shell
import jenkins.security.ApiTokenProperty
import com.cloudbees.hudson.plugins.folder.Folder
import org.jenkinsci.plugins.workflow.job.WorkflowJob
import org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition

def j = Jenkins.get()
// Once: at a restart, Jenkins runs this again, and there is nothing to do.
if (j.getItem('pass') != null) { return }
// Passwords no one needs: the tests use the API tokens.
def rnd = new java.security.SecureRandom()
def pw = { new BigInteger(130, rnd).toString(32) }
def realm = new HudsonPrivateSecurityRealm(false)
def users = ['admin', 'monitor', 'reader'].collectEntries { [(it): realm.createAccount(it, pw())] }
def out = new File(j.getRootDir(), 'vigil')
out.mkdirs()
out.setReadable(false, false); out.setReadable(true, true); out.setExecutable(false, false); out.setExecutable(true, true)
j.setSecurityRealm(realm)
def s = new GlobalMatrixAuthorizationStrategy()
s.add(Jenkins.ADMINISTER, 'admin')
// monitor: read-only, and SystemRead for the plugins; reader: read-only.
['monitor', 'reader'].each { u ->
    s.add(Jenkins.READ, u); s.add(Item.READ, u); s.add(Computer.EXTENDED_READ, u)
}
s.add(Jenkins.SYSTEM_READ, 'monitor')
j.setAuthorizationStrategy(s)
j.setNumExecutors(2)
j.save()
users.each { name, u ->
    def t = u.getProperty(ApiTokenProperty).tokenStore.generateNewToken('vigil')
    u.save()
    def f = new File(out, "${name}-token")
    f.text = t.plainValue
    f.setReadable(false, false); f.setReadable(true, true)
}

// Two agents that never connect: one offline, one taken offline by hand.
['linux-agent', 'maint-agent'].each { n ->
    def a = new DumbSlave(n, '/tmp/' + n, new JNLPLauncher(true))
    a.setNumExecutors(1)
    a.setLabelString('agents')
    j.addNode(a)
}
j.getComputer('maint-agent').setTemporarilyOffline(true, new OfflineCause.ByCLI('patching, back Monday'))

def shell = { name, cmd, parent = j ->
    def p = parent.createProject(FreeStyleProject, name)
    p.getBuildersList().add(new Shell(cmd))
    p.save()
    p
}
def pass = shell('pass', 'echo fine')
def fail = shell('fail', 'echo broken; exit 1')
def disabled = shell('disabled', 'true'); disabled.disable()
shell('never', 'true')
def team = j.createProject(Folder, 'team')
def nightly = shell('nightly', 'echo nightly; exit 1', team)
def unstable = j.createProject(WorkflowJob, 'unstable')
unstable.setDefinition(new CpsFlowDefinition("unstable('two tests failed')", true))
unstable.save()
// First 3 seconds, then 15 minutes: far past its estimate.
def slow = shell('slow', 'if [ -f "$JENKINS_HOME/slow-once" ]; then sleep 900; else touch "$JENKINS_HOME/slow-once"; sleep 3; fi')
// Waits for a label no node has.
def waiting = shell('waiting', 'true')
waiting.setAssignedLabel(j.getLabel('nowhere'))
waiting.save()

[pass, fail, nightly, unstable, slow].each { it.scheduleBuild2(0) }
Thread.start {
    while (slow.getLastCompletedBuild() == null) { sleep(2000) }
    slow.scheduleBuild2(0)
    waiting.scheduleBuild2(0)
}
new File(out, 'ready').text = 'ok'
