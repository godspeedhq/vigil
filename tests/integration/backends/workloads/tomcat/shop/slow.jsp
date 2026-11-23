<%-- Copyright (c) Bankole Ogundero and the Vigil contributors. SPDX-License-Identifier: Apache-2.0.
     Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND; see the LICENSE file.
     slow.jsp?s=N - a request that takes N seconds: past 5, the valve calls it stuck. --%>
<%@ page session="false" %><% Thread.sleep(Long.parseLong(request.getParameter("s")) * 1000L); %>slow
