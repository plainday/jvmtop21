/*
 * Copyright (c) 2005, 2006, Oracle and/or its affiliates. All rights reserved.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.  Oracle designates this
 * particular file as subject to the "Classpath" exception as provided
 * by Oracle in the LICENSE file that accompanied this code.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 * Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
 * or visit www.oracle.com if you need additional information or have any
 * questions.
 *
 */

/*
 * This file has been modified by jvmtop project authors.
 * JDK 21 port: removed sun.jvmstat.monitor.* (getMonitoredVMs path) and
 * sun.management.ConnectorAddressLink — VM discovery now relies solely on
 * the public VirtualMachine.list() API (jdk.attach module).
 * loadManagementAgent() replaced with VirtualMachine.startLocalManagementAgent()
 * which is available in JDK 9+ and does not require management-agent.jar.
 */
package com.jvmtop.openjdk.tools;

import java.io.IOException;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;

import com.sun.tools.attach.AttachNotSupportedException;
import com.sun.tools.attach.VirtualMachine;
import com.sun.tools.attach.VirtualMachineDescriptor;

public class LocalVirtualMachine
{
  private String  address;

  private String  commandLine;

  private String  displayName;

  private int     vmid;

  private boolean isAttachSupported;

  private static boolean J9Mode = false;

  static
  {
    if (System.getProperty("java.vm.name").contains("IBM J9"))
    {
      J9Mode = true;
      System.setProperty("com.ibm.tools.attach.timeout", "5000");
    }
  }

  public static boolean isJ9Mode()
  {
    return J9Mode;
  }

  public LocalVirtualMachine(int vmid, String commandLine, boolean canAttach,
      String connectorAddress)
  {
    this.vmid = vmid;
    this.commandLine = commandLine;
    this.address = connectorAddress;
    this.isAttachSupported = canAttach;
    this.displayName = getDisplayName(commandLine);
  }

  private static String getDisplayName(String commandLine)
  {
    // trim the pathname of jar file if it's a jar
    String[] res = commandLine.split(" ", 2);
    if (res[0].endsWith(".jar"))
    {
      java.io.File jarfile = new java.io.File(res[0]);
      String displayName = jarfile.getName();
      if (res.length == 2)
      {
        displayName += " " + res[1];
      }
      return displayName;
    }
    return commandLine;
  }

  public int vmid()
  {
    return vmid;
  }

  public boolean isManageable()
  {
    return (address != null);
  }

  public boolean isAttachable()
  {
    return isAttachSupported;
  }

  public void startManagementAgent() throws IOException
  {
    if (address != null)
    {
      // already started
      return;
    }

    if (!isAttachable())
    {
      throw new IOException("This virtual machine \"" + vmid
          + "\" does not support dynamic attach.");
    }

    loadManagementAgent();
    // fails to load or start the management agent
    if (address == null)
    {
      // should never reach here
      throw new IOException("Fails to find connector address");
    }
  }

  public String connectorAddress()
  {
    // return null if not available or no JMX agent
    return address;
  }

  public String displayName()
  {
    return displayName;
  }

  @Override
  public String toString()
  {
    return commandLine;
  }

  // This method returns the list of all virtual machines currently
  // running on the machine.
  // JDK 21 port: uses only VirtualMachine.list() (jdk.attach, public API).
  // The sun.jvmstat.monitor.* path (getMonitoredVMs) was removed because
  // jvmstat internals are not exported in JDK 9+.
  public static Map<Integer, LocalVirtualMachine> getAllVirtualMachines()
  {
    Map<Integer, LocalVirtualMachine> map = new HashMap<>();
    getAttachableVMs(map, Collections.emptyMap());
    return map;
  }

  // Returns VMs not already in existingVmMap.
  public static Map<Integer, LocalVirtualMachine> getNewVirtualMachines(
      Map<Integer, LocalVirtualMachine> existingVmMap)
  {
    Map<Integer, LocalVirtualMachine> map = new HashMap<>(existingVmMap);
    getAttachableVMs(map, existingVmMap);
    return map;
  }

  private static final String LOCAL_CONNECTOR_ADDRESS_PROP =
      "com.sun.management.jmxremote.localConnectorAddress";

  /**
   * Builds the VM list using only VirtualMachineDescriptor (id, displayName)
   * from VirtualMachine.list() — no attach is performed here.
   *
   * All discovered VMs are recorded as attachable=true, address=null.
   * The JMX connector address is resolved lazily, per-VM, when
   * VMInfo.processNewVM() → ProxyClient.connect() calls startManagementAgent()
   * → loadManagementAgent() → VirtualMachine.attach(). This defers the
   * expensive attach to the first overview refresh cycle and prevents slow VMs
   * from blocking the initial list-building step (see §8.3 in PHASE0_ANALYSIS).
   */
  private static void getAttachableVMs(Map<Integer, LocalVirtualMachine> map,
      Map<Integer, LocalVirtualMachine> existingVmMap)
  {
    List<VirtualMachineDescriptor> vms = VirtualMachine.list();
    for (VirtualMachineDescriptor vmd : vms)
    {
      try
      {
        Integer vmid = Integer.valueOf(vmd.id());
        if (map.containsKey(vmid) || existingVmMap.containsKey(vmid))
        {
          continue;
        }
        // No attach: descriptor provides id and displayName without any IPC.
        // address=null causes ProxyClient.connect() to call startManagementAgent()
        // on first use, which performs exactly one VirtualMachine.attach() per VM.
        map.put(vmid,
            new LocalVirtualMachine(vmid.intValue(), vmd.displayName(),
                true, null));
      }
      catch (NumberFormatException e)
      {
        // do not support vmid different than pid
      }
    }
  }

  public static LocalVirtualMachine getLocalVirtualMachine(int vmid)
      throws Exception
  {
    // Detail mode: resolve display name from the descriptor list (no attach —
    // VirtualMachine.list() is a fast IPC-free enumeration), then attach only
    // to the requested vmid. No scan of other VMs on the system.
    String displayName = String.valueOf(vmid);
    for (VirtualMachineDescriptor vmd : VirtualMachine.list())
    {
      if (vmd.id().equals(String.valueOf(vmid)))
      {
        displayName = vmd.displayName();
        break;
      }
    }

    VirtualMachine vm = VirtualMachine.attach(String.valueOf(vmid));
    Properties agentProps = vm.getAgentProperties();
    String address = (String) agentProps.get(LOCAL_CONNECTOR_ADDRESS_PROP);
    vm.detach();
    return new LocalVirtualMachine(vmid, displayName, true, address);
  }

  public static LocalVirtualMachine getDelegateMachine(VirtualMachine vm)
      throws IOException
  {
    boolean attachable = true;
    Properties agentProps = vm.getAgentProperties();
    String address = (String) agentProps.get(LOCAL_CONNECTOR_ADDRESS_PROP);
    String name = String.valueOf(vm.id());
    vm.detach();
    return new LocalVirtualMachine(Integer.parseInt(vm.id()), name, attachable,
        address);
  }

  /**
   * Loads the management agent into the target VM to enable JMX.
   *
   * JDK 21 port: VirtualMachine.startLocalManagementAgent() is used instead
   * of loading management-agent.jar by path. The jar was removed in JDK 9+
   * and its functionality is now built into the JDK.
   * startLocalManagementAgent() returns the connector address directly.
   */
  private void loadManagementAgent() throws IOException
  {
    VirtualMachine vm = null;
    String name = String.valueOf(vmid);
    try
    {
      vm = VirtualMachine.attach(name);
    }
    catch (AttachNotSupportedException x)
    {
      IOException ioe = new IOException(x.getMessage());
      ioe.initCause(x);
      throw ioe;
    }

    try
    {
      // startLocalManagementAgent() starts the JMX agent and returns
      // the local connector address. Available since JDK 9.
      // Throws IOException only (AgentLoadException/AgentInitializationException
      // are not thrown by this API).
      this.address = vm.startLocalManagementAgent();
    }
    finally
    {
      vm.detach();
    }
  }
}
