<%-- Copyright (c) Bankole Ogundero and the Vigil contributors. SPDX-License-Identifier: Apache-2.0.
     Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND; see the LICENSE file.
     fail.jsp - a request that fails: an exception, so a 500. --%>
<%@ page session="false" %><% if (request != null) throw new IllegalStateException("fails on purpose"); %>
