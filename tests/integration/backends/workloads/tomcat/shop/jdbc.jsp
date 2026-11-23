<%-- Copyright (c) Bankole Ogundero and the Vigil contributors. SPDX-License-Identifier: Apache-2.0.
     Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND; see the LICENSE file.
     jdbc.jsp?db=shop|orders&s=N - takes a connection from that pool and holds
     it N seconds: more at once than the pool has, and the rest wait, then fail. --%>
<%@ page session="false" import="javax.naming.InitialContext,javax.sql.DataSource,java.sql.Connection" %><%
    DataSource ds = (DataSource) new InitialContext().lookup("java:comp/env/jdbc/" + request.getParameter("db"));
    try (Connection c = ds.getConnection()) {
        Thread.sleep(Long.parseLong(request.getParameter("s")) * 1000L);
    }
%>held
